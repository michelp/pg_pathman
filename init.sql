/* ------------------------------------------------------------------------
 *
 * init.sql
 *		Creates config table and provides common utility functions
 *
 * Copyright (c) 2015-2016, Postgres Professional
 *
 * ------------------------------------------------------------------------
 */

/*
 * Pathman config
 *		partrel - regclass (relation type, stored as Oid)
 *		attname - partitioning key
 *		parttype - partitioning type:
 *			1 - HASH
 *			2 - RANGE
 *		range_interval - base interval for RANGE partitioning as string
 */
CREATE TABLE IF NOT EXISTS @extschema@.pathman_config (
	id				SERIAL PRIMARY KEY,
	partrel			REGCLASS NOT NULL,
	attname			TEXT NOT NULL,
	parttype		INTEGER NOT NULL,
	range_interval	TEXT,

	CHECK (parttype >= 1 OR parttype <= 2) /* check for allowed part types */
);


SELECT pg_catalog.pg_extension_config_dump('@extschema@.pathman_config', '');


/*
 * Copy rows to partitions
 */
CREATE OR REPLACE FUNCTION @extschema@.partition_data(
	p_parent regclass
	, p_invalidate_cache_on_error BOOLEAN DEFAULT FALSE
	, OUT p_total BIGINT)
AS
$$
DECLARE
	relname TEXT;
	rec RECORD;
	cnt BIGINT := 0;
BEGIN
	relname := @extschema@.validate_relname(p_parent);

	p_total := 0;

	/* Create partitions and copy rest of the data */
	RAISE NOTICE 'Copying data to partitions...';
	EXECUTE format('
				WITH part_data AS (
					DELETE FROM ONLY %s RETURNING *)
				INSERT INTO %s SELECT * FROM part_data'
				, relname
				, relname);
	GET DIAGNOSTICS p_total = ROW_COUNT;
	RETURN;
END
$$
LANGUAGE plpgsql;

/*
 * Disable pathman partitioning for specified relation
 */
CREATE OR REPLACE FUNCTION @extschema@.disable_partitioning(relation regclass)
RETURNS VOID AS
$$
BEGIN
	relation := @extschema@.validate_relname(relation);

	DELETE FROM @extschema@.pathman_config WHERE partrel = relation;
	PERFORM @extschema@.drop_triggers(relation);

	/* Notify backend about changes */
	PERFORM on_remove_partitions(relation::regclass::integer);
END
$$
LANGUAGE plpgsql;

/*
 * Aggregates several common relation checks before partitioning. Suitable for every partitioning type.
 */
CREATE OR REPLACE FUNCTION @extschema@.common_relation_checks(
	p_relation REGCLASS
	, p_attribute TEXT)
RETURNS BOOLEAN AS
$$
DECLARE
	v_rec RECORD;
	is_referenced BOOLEAN;
BEGIN
	IF EXISTS (SELECT * FROM @extschema@.pathman_config WHERE partrel = p_relation) THEN
		RAISE EXCEPTION 'Relation "%" has already been partitioned', p_relation;
	END IF;

	IF @extschema@.is_attribute_nullable(p_relation, p_attribute) THEN
		RAISE EXCEPTION 'Partitioning key ''%'' must be NOT NULL', p_attribute;
	END IF;

	/* Check if there are foreign keys reference to the relation */
	FOR v_rec IN (SELECT *
				  FROM pg_constraint WHERE confrelid = p_relation::regclass::oid)
	LOOP
		is_referenced := TRUE;
		RAISE WARNING 'Foreign key ''%'' references to the relation ''%''', v_rec.conname, p_relation;
	END LOOP;

	IF is_referenced THEN
		RAISE EXCEPTION 'Relation ''%'' is referenced from other relations', p_relation;
	END IF;

	RETURN TRUE;
END
$$
LANGUAGE plpgsql;

/*
 * Returns relname without quotes or something
 */
CREATE OR REPLACE FUNCTION @extschema@.get_plain_schema_and_relname(cls regclass, OUT schema TEXT, OUT relname TEXT)
AS
$$
BEGIN
	SELECT relnamespace::regnamespace, pg_class.relname FROM pg_class WHERE oid = cls::oid
	INTO schema, relname;
END
$$
LANGUAGE plpgsql;

/*
 * Validates relation name. It must be schema qualified
 */
CREATE OR REPLACE FUNCTION @extschema@.validate_relname(cls regclass)
RETURNS TEXT AS
$$
BEGIN
	RETURN @extschema@.get_schema_qualified_name(cls, '.');
END
$$
LANGUAGE plpgsql;

/*
 * Returns schema-qualified name for table
 */
CREATE OR REPLACE FUNCTION @extschema@.get_schema_qualified_name(
	cls REGCLASS
	, delimiter TEXT DEFAULT '_'
	, suffix TEXT DEFAULT '')
RETURNS TEXT AS
$$
BEGIN
	RETURN (SELECT quote_ident(relnamespace::regnamespace::text) ||
				   delimiter ||
				   quote_ident(relname || suffix)
			FROM pg_class
			WHERE oid = cls::oid);
END
$$
LANGUAGE plpgsql;

/*
 * Check if two relations have equal structures
 */
CREATE OR REPLACE FUNCTION @extschema@.validate_relations_equality(relation1 OID, relation2 OID)
RETURNS BOOLEAN AS
$$
DECLARE
	rec RECORD;
BEGIN
	FOR rec IN (
		WITH
			a1 AS (select * from pg_attribute where attrelid = relation1 and attnum > 0),
			a2 AS (select * from pg_attribute where attrelid = relation2 and attnum > 0)
		SELECT a1.attname name1, a2.attname name2, a1.atttypid type1, a2.atttypid type2
		FROM a1
		FULL JOIN a2 ON a1.attnum = a2.attnum
	)
	LOOP
		IF rec.name1 IS NULL OR rec.name2 IS NULL OR rec.name1 != rec.name2 THEN
			RETURN False;
		END IF;
	END LOOP;

	RETURN True;
END
$$
LANGUAGE plpgsql;

/*
 * DDL trigger that deletes entry from pathman_config table
 */
CREATE OR REPLACE FUNCTION @extschema@.pathman_ddl_trigger_func()
RETURNS event_trigger AS
$$
DECLARE
	obj record;
BEGIN
	FOR obj IN SELECT * FROM pg_event_trigger_dropped_objects() as events
			   JOIN @extschema@.pathman_config as cfg
			   ON partrel::oid = events.objid
	LOOP
		IF obj.object_type = 'table' THEN
			EXECUTE 'DELETE FROM @extschema@.pathman_config WHERE partrel = $1'
			USING obj.objid;
		END IF;
	END LOOP;
END
$$
LANGUAGE plpgsql;

/*
 * Drop trigger
 */
CREATE OR REPLACE FUNCTION @extschema@.drop_triggers(IN relation REGCLASS)
RETURNS VOID AS
$$
DECLARE
	relname		TEXT;
	schema		TEXT;
	funcname	TEXT;
BEGIN
	SELECT * INTO schema, relname
	FROM @extschema@.get_plain_schema_and_relname(relation);

	funcname := schema || '.' || quote_ident(format('%s_update_trigger_func', relname));
	EXECUTE format('DROP FUNCTION IF EXISTS %s() CASCADE', funcname);
END
$$ LANGUAGE plpgsql;

/*
 * Drop partitions
 * If delete_data set to TRUE then partitions will be dropped with all the data
 */
CREATE OR REPLACE FUNCTION @extschema@.drop_partitions(
	relation REGCLASS
	, delete_data BOOLEAN DEFAULT FALSE)
RETURNS INTEGER AS
$$
DECLARE
	v_rec        RECORD;
	v_rows       INTEGER;
	v_part_count INTEGER := 0;
	v_relname    TEXT;
	conf_num_del INTEGER;
BEGIN
	v_relname := @extschema@.validate_relname(relation);

	/* Drop trigger first */
	PERFORM @extschema@.drop_triggers(relation);

	WITH config_num_deleted AS (DELETE FROM @extschema@.pathman_config
								WHERE partrel = relation
								RETURNING *)
	SELECT count(*) from config_num_deleted INTO conf_num_del;

	IF conf_num_del = 0 THEN
		RAISE EXCEPTION 'table % has no partitions', relation::text;
	END IF;

	FOR v_rec IN (SELECT inhrelid::regclass::text AS tbl
				  FROM pg_inherits WHERE inhparent::regclass = relation)
	LOOP
		IF NOT delete_data THEN
			EXECUTE format('WITH part_data AS (DELETE FROM %s RETURNING *)
							INSERT INTO %s SELECT * FROM part_data'
						   , v_rec.tbl
						   , relation::text);
			GET DIAGNOSTICS v_rows = ROW_COUNT;
			RAISE NOTICE '% rows copied from %', v_rows, v_rec.tbl;
		END IF;
		EXECUTE format('DROP TABLE %s', v_rec.tbl);
		v_part_count := v_part_count + 1;
	END LOOP;

	/* Notify backend about changes */
	PERFORM @extschema@.on_remove_partitions(relation::oid);

	RETURN v_part_count;
END
$$ LANGUAGE plpgsql
SET pg_pathman.enable_partitionfilter = off;



CREATE EVENT TRIGGER pathman_ddl_trigger
ON sql_drop
EXECUTE PROCEDURE @extschema@.pathman_ddl_trigger_func();


/*
 * Acquire partitions lock to prevent concurrent partitions creation
 */
CREATE OR REPLACE FUNCTION @extschema@.acquire_partitions_lock()
RETURNS VOID AS 'pg_pathman', 'acquire_partitions_lock'
LANGUAGE C STRICT;

/*
 * Release partitions lock
 */
CREATE OR REPLACE FUNCTION @extschema@.release_partitions_lock()
RETURNS VOID AS 'pg_pathman', 'release_partitions_lock'
LANGUAGE C STRICT;

/*
 * Check if regclass is date or timestamp
 */
CREATE OR REPLACE FUNCTION @extschema@.is_date_type(cls REGTYPE)
RETURNS BOOLEAN AS 'pg_pathman', 'is_date_type'
LANGUAGE C STRICT;


CREATE OR REPLACE FUNCTION @extschema@.on_create_partitions(relid OID)
RETURNS VOID AS 'pg_pathman', 'on_partitions_created'
LANGUAGE C STRICT;

CREATE OR REPLACE FUNCTION @extschema@.on_update_partitions(relid OID)
RETURNS VOID AS 'pg_pathman', 'on_partitions_updated'
LANGUAGE C STRICT;

CREATE OR REPLACE FUNCTION @extschema@.on_remove_partitions(relid OID)
RETURNS VOID AS 'pg_pathman', 'on_partitions_removed'
LANGUAGE C STRICT;


/*
 * Checks if attribute is nullable
 */
CREATE OR REPLACE FUNCTION @extschema@.is_attribute_nullable(REGCLASS, TEXT)
RETURNS BOOLEAN AS 'pg_pathman', 'is_attribute_nullable'
LANGUAGE C STRICT;

/*
 * Returns attribute type name for relation
 */
CREATE OR REPLACE FUNCTION @extschema@.get_attribute_type_name(REGCLASS, TEXT)
RETURNS TEXT AS 'pg_pathman', 'get_attribute_type_name'
LANGUAGE C STRICT;

/*
 * Build check constraint name for a specified relation's column
 */
CREATE OR REPLACE FUNCTION @extschema@.build_check_constraint_name(REGCLASS, INT2)
RETURNS TEXT AS 'pg_pathman', 'build_check_constraint_name_attnum'
LANGUAGE C STRICT;

CREATE OR REPLACE FUNCTION @extschema@.build_check_constraint_name(REGCLASS, TEXT)
RETURNS TEXT AS 'pg_pathman', 'build_check_constraint_name_attname'
LANGUAGE C STRICT;

/*
 * DEBUG: Place this inside some plpgsql fuction and set breakpoint.
 */
CREATE OR REPLACE FUNCTION @extschema@.debug_capture()
RETURNS VOID AS 'pg_pathman', 'debug_capture'
LANGUAGE C STRICT;

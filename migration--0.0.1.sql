-- Migrations :: (c) Drew Crampsie - 2018
-- Contact: me@drewc.ca

 -- DROP TABLE migration_registry CASCADE;
CREATE TABLE IF NOT EXISTS migration_registry (
 number numeric PRIMARY KEY, 
 up TEXT NOT NULL,
 down TEXT NOT NULL,
 status BOOLEAN NOT NULL DEFAULT false
);

CREATE OR REPLACE FUNCTION register_migration
  (_number NUMERIC, _up TEXT, _down TEXT, _overwrite BOOLEAN DEFAULT false)
 RETURNS migration_registry LANGUAGE PLPGSQL AS $$
 DECLARE 
  _exists migration_registry;
 BEGIN

  SELECT r.* INTO _exists 
   FROM migration_registry AS r
  WHERE r.number = $1; 

  IF ((NOT $4) AND _exists.number IS NOT NULL) THEN
   RAISE EXCEPTION 'ERROR: Migration % exists.
     If you want to overwrite it, set overwrite to gtrue.',$1 ;
  ELSEIF (_exists.status) THEN
   RAISE EXCEPTION 'ERROR: Migration % has aleady been run. Cannot Overwrite',$1 ;
  END IF;

 IF (_exists.status IS NULL) THEN
  INSERT INTO migration_registry(number, up, down)
   VALUES ($1, $2, $3);
 ELSE
  UPDATE migration_registry AS r SET up = $2, down=$3 WHERE r.number = $1;
 END IF;

 SELECT r.* INTO _exists 
   FROM migration_registry AS r
  WHERE r.number = $1; 

 RETURN _exists ;

 END; $$; 

CREATE OR REPLACE FUNCTION register_migration
  (_up TEXT, _down TEXT, _overwrite BOOLEAN DEFAULT false)
 RETURNS migration_registry LANGUAGE SQL AS $$
 SELECT register_migration((1 + (select COALESCE(max(number), -1) FROM migration_registry))
			   ,$1,$2,$3) ;
$$;

CREATE TABLE IF NOT EXISTS migration_env (
 name TEXT PRIMARY KEY, 
 value TEXT);

CREATE OR REPLACE FUNCTION migration_env ()
 RETURNS json LANGUAGE SQL AS $$
  SELECT json_object_agg(env.name, env.value) AS env
  FROM migration_env AS env;
 $$;

CREATE OR REPLACE FUNCTION migration_getenv (name TEXT)
 RETURNS TEXT LANGUAGE SQL AS $$
  SELECT env.value FROM migration_env AS env 
   WHERE env.name = $1;
 $$;

CREATE OR REPLACE FUNCTION migration_setenv
   (name text, value text, overwrite BOOLEAN DEFAULT true)
 RETURNS TEXT LANGUAGE SQL AS $$ 

 INSERT INTO migration_env(name, value) 
  VALUES ($1, $2)
  ON CONFLICT (name) DO 
   UPDATE SET value = EXCLUDED.value 
  WHERE $3 AND migration_env.name = EXCLUDED.name;
 
 SELECT migration_getenv($1);

$$;

CREATE OR REPLACE FUNCTION migration_unsetenv (name TEXT)
 RETURNS BOOLEAN LANGUAGE SQL AS $$
  DELETE FROM migration_env AS env 
   WHERE env.name = $1;
  SELECT TRUE;
 $$;

--DROP FUNCTION migration_read_file(text);
CREATE OR REPLACE FUNCTION migration_read_file(_pathname text)
  RETURNS text AS $$
    DECLARE
      content text;
      tmp text;
      root_directory text := '';
    BEGIN
      -- First, make the pathname proper.
      -- If it is relative, getenv('ROOT_DIRECTORY');
      IF ((left(_pathname, 1)) != '/') THEN 
	SELECT migration_getenv('ROOT_DIRECTORY') INTO root_directory; 

	-- If there's none, make it an empty string. The path will be
	-- interpreted relative to the working directory of the server
	-- process (normally the cluster's data directory), not the
	-- client's working directory.

 	IF (root_directory IS NULL) THEN root_directory := '' ;

	-- If there's a root directory that's not '', make sure it ends
	-- with a slash.

	ELSIF (root_directory != '') THEN 
	root_directory := trim( trailing '/' from root_directory) || '/' ;
	END IF;

      END IF;
      _pathname := quote_literal(root_directory||_pathname);

      SELECT array_to_string(ARRAY(SELECT chr((65 + round(random() * 25)) :: integer) 
       INTO tmp
       FROM generate_series(1,7)), '');

      tmp := quote_ident(tmp);

      EXECUTE 'CREATE TEMP TABLE ' || tmp || ' (content text)';
      EXECUTE 'COPY ' || tmp || ' FROM ' || _pathname ||' WITH DELIMITER E''\031''';
      EXECUTE 'SELECT string_agg(content,chr(10)) FROM ' || tmp INTO content;
      EXECUTE 'DROP TABLE ' || tmp;

      RETURN content;
    END;
  $$ LANGUAGE plpgsql VOLATILE;

-- DROP TABLE migration_error CASCADE;
  CREATE TABLE IF NOT EXISTS migration_error (
   error_number SERIAL PRIMARY KEY,
   migration_number INTEGER,
   direction TEXT,
   -- the SQLSTATE error code of the exception
   RETURNED_SQLSTATE TEXT,
   -- the name of the column related to exception 
   COLUMN_NAME TEXT,
    -- the name of the constraint related to exception 
   CONSTRAINT_NAME TEXT,
    -- the name of the data type related to exception
   PG_DATATYPE_NAME TEXT,
   -- the text of the exception's primary message
   MESSAGE_TEXT TEXT,
   -- the name of the table related to exception
   TABLE_NAME TEXT,
    -- the name of the schema related to exception
   SCHEMA_NAME TEXT,
   --	the text of the exception's detail message, if any
   PG_EXCEPTION_DETAIL TEXT,
   -- the text of the exception's hint message, if any
   PG_EXCEPTION_HINT TEXT,
   -- line(s) of text describing the call stack at the time of the exception
   PG_EXCEPTION_CONTEXT TEXT 
  );

CREATE OR REPLACE FUNCTION handle_migration_error
 (query text) RETURNS migration_error AS $$
DECLARE
 -- the SQLSTATE error code of the exception
   RETURNED_SQLSTATE TEXT ;
   -- the name of the column related to exception 
   COLUMN_NAME TEXT;
    -- the name of the constraint related to exception 
   CONSTRAINT_NAME TEXT;
    -- the name of the data type related to exception
   PG_DATATYPE_NAME TEXT;
   -- the text of the exception's primary message
   MESSAGE_TEXT TEXT;
   -- the name of the table related to exception
   TABLE_NAME TEXT;
    -- the name of the schema related to exception
   SCHEMA_NAME TEXT;
   --	the text of the exception's detail message; if any
   PG_EXCEPTION_DETAIL TEXT;
   -- the text of the exception's hint message; if any
   PG_EXCEPTION_HINT TEXT;
   -- line(s) of text describing the call stack at the time of the exception
   PG_EXCEPTION_CONTEXT TEXT ;
  stack text;
  msg text;
BEGIN
 
   EXECUTE $1 ;
  RETURN null::migration_error;
 EXCEPTION WHEN OTHERS THEN 
 GET STACKED DIAGNOSTICS 
   RETURNED_SQLSTATE = RETURNED_SQLSTATE,
   COLUMN_NAME = COLUMN_NAME,
   CONSTRAINT_NAME = CONSTRAINT_NAME,
   PG_DATATYPE_NAME = PG_DATATYPE_NAME,
   MESSAGE_TEXT = MESSAGE_TEXT,
   TABLE_NAME = TABLE_NAME,
   SCHEMA_NAME = SCHEMA_NAME,
   PG_EXCEPTION_DETAIL = PG_EXCEPTION_DETAIL,
   PG_EXCEPTION_HINT = PG_EXCEPTION_HINT,
   PG_EXCEPTION_CONTEXT = PG_EXCEPTION_CONTEXT;

 RETURN ROW(null, null, null, RETURNED_SQLSTATE,
   COLUMN_NAME,
   CONSTRAINT_NAME,
   PG_DATATYPE_NAME,
   MESSAGE_TEXT,
   TABLE_NAME,
   SCHEMA_NAME,
   PG_EXCEPTION_DETAIL,
   PG_EXCEPTION_HINT,
   PG_EXCEPTION_CONTEXT)::migration_error;

   
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION report_migration_error(_me migration_error)
 RETURNS migration_error LANGUAGE sql AS $$ 
  INSERT INTO migration_error
     (migration_number, direction,
      RETURNED_SQLSTATE,
      COLUMN_NAME,
      CONSTRAINT_NAME,
      PG_DATATYPE_NAME,
      MESSAGE_TEXT,
      TABLE_NAME,
      SCHEMA_NAME,
      PG_EXCEPTION_DETAIL,
      PG_EXCEPTION_HINT,
      PG_EXCEPTION_CONTEXT)
   VALUES (_me.migration_number, _me.direction,
      _me.RETURNED_SQLSTATE,
      _me.COLUMN_NAME,
      _me.CONSTRAINT_NAME,
      _me.PG_DATATYPE_NAME,
      _me.MESSAGE_TEXT,
      _me.TABLE_NAME,
      _me.SCHEMA_NAME,
      _me.PG_EXCEPTION_DETAIL,
      _me.PG_EXCEPTION_HINT,
      _me.PG_EXCEPTION_CONTEXT)
  RETURNING migration_error ;
$$;

CREATE OR REPLACE FUNCTION migration_eval(text)
  RETURNS void LANGUAGE PLPGSQL AS $$
BEGIN
 EXECUTE $1;
END;
$$;

CREATE OR REPLACE FUNCTION migration_run
 (_m migration_registry, _direction TEXT DEFAULT 'up')
 RETURNS migration_registry LANGUAGE SQL AS $$

  SELECT CASE 
          WHEN (_direction = 'up') THEN 
            migration_eval(migration_read_file(_m.up))
          WHEN (_direction = 'down') THEN 
            migration_eval(migration_read_file(_m.down))
	 END;

  UPDATE migration_registry SET status = (_direction = 'up')
   WHERE number = _m.number RETURNING migration_registry ;

$$;

CREATE OR REPLACE FUNCTION migration_run
 (_m numeric, _direction TEXT DEFAULT 'up')
 RETURNS migration_registry LANGUAGE SQL AS $$
  SELECT migration_run(m, $2) FROM migration_registry AS m 
   WHERE number = $1;
$$;


-- DROP TABLE migration_log;
CREATE TABLE IF NOT EXISTS migration_log (
 time timestamp without time zone DEFAULT now (),
 completed BOOLEAN NOT NULL DEFAULT false,
 migration_number INTEGER NOT NULL REFERENCES migration_registry(number), 
 direction TEXT NOT NULL DEFAULT 'up', -- or 'down'
 error INTEGER REFERENCES migration_error(error_number) DEFAULT NULL
);


CREATE OR REPLACE FUNCTION migration_current_number() 
RETURNS numeric LANGUAGE SQL AS $$
 SELECT COALESCE(max(number), -1) FROM migration_registry WHERE status = true;
$$ ;

CREATE OR REPLACE FUNCTION migration_migrate_database
 (_migration NUMERIC default NULL::int)
RETURNS migration_log LANGUAGE PLPGSQL AS $$
DECLARE 
 _current numeric;
 _next numeric;
 _version numeric;
 _direction text;
 _error migration_error;
 _log migration_log;
 _completed boolean := false;
BEGIN

 _current := migration_current_number();
 _version := $1;

 -- RAISE NOTICE ' Trying current % to version %', _current, _version;

 -- Up
 IF (_version IS NULL OR (_version > _current AND _version >= 0)) THEN
   _next := _current + 1;
   _direction := 'up';

 -- Down  
  ELSIF (_version < _current) THEN 
  _next := _current;
  _direction := 'down';

  -- Nothing at all, done!
ELSE 
  RETURN _log;
END IF;

--  RAISE EXCEPTION 'So next is  % direction %, foo%', _next, _direction, 'SELECT migration_run('||_next ||','''|| _direction||''')' ;

--- Do the migration, handle any errors

SELECT handle_migration_error('SELECT migration_run('||_next ||','''|| _direction||''')') 
  INTO _error;

IF (_error.error_number IS NOT NULL) THEN
  _error.migration_number = _next;
  _error.direction = _direction;
  PERFORM  report_migration_error(_error);
ELSE 
 _completed := true;
END IF;

-- Log it.

INSERT INTO migration_log(completed, migration_number, direction, error)
  VALUES (_completed, _next, _direction, _error.error_number)
  RETURNING migration_log.* INTO _log;

-- If it failed, return now.

IF (NOT _completed) THEN
 RETURN _log;
END IF;

IF (_direction = 'down') THEN
 _next := _next - 1;
END IF;

IF ((_version IS NULL) OR ( _version != _next AND _version != _current AND _next >= 0)) THEN
 RETURN (SELECT migration_migrate_database(_version));
ELSE 
 RETURN _log;
END IF;

EXCEPTION 
  WHEN undefined_file THEN
   IF (_version IS NULL) THEN
     RETURN NULL;
   ELSE 
    RAISE EXCEPTION 'Error %', SQLERRM USING ERRCODE = SQLSTATE ;
  END IF;
END; 
$$;

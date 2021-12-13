# PostgreSQL database dump scripts

## pg_db_dump_file.sh

Dump all database in a cluster, each database gets its own file. pg globals is dumped extra.

Via settings the keep time or keep amount can be set.
Also database can be exluded or only serval databases selected for dump.

The file format is dump standard for automatic restore via pg_drop_restore.sh or pg_restore_db_file.sh

`<database name>.<owner>.<database type>-<version>_<host>_<port>_<date in YYYYMMDD>_<time in HHMM>_<sequenze>`

## pg_drop_restore.sh

Counterpart to pg_db_dump_file.sh. Restores a single file to one database. If the standard file name is given, will restore as set in the file name.

## pg_restore_db_file.sh

Mass restore for dumped files. It will first try to restore the pg globals file and then all databse files.

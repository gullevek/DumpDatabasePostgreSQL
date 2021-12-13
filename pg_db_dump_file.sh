#!/bin/bash

set -e -u -o pipefail

# dumps all the databases in compressed (custom) format
# EXCLUDE: space seperated list of database names to be skipped
# KEEP: how many files to keep, eg 3 means, keep 3 days + todays backup
# the file format includes the database name and owner:
# <database name>.<owner>.<database type>-<version>_<host>_<port>_<date in YYYYMMDD>_<time in HHMM>_<sequenze in two digits with leading 0>.sql

function usage ()
{
	cat <<- EOT
	Usage: ${0##/*/} [-t] [-s] [-g] [-c] [-r|-a] [-k <number to keep>] [-n] [-b <path>] [-i <postgreSQL version>] [-d <dump database name> [-d ...]] [-e <exclude dump> [-e ...]] [-u <db user>] [-h <db host>] [-p <db port>] [-l <db password>] [-L <log path>]

	-t: test usage, no real backup is done
	-s: turn ON ssl mode, default mode is off
	-g: turn OFF dumping globals data, default is dumping globals data
	-c: run clean up of old files before data is dumped. Default is run after data dump.
	-k <number>: keep how many backups, default is 3 days/files
	-n: keep files in numbers not in days
	-b <path>: backup target path, if not set, /mnt/backup/db_dumps_fc/ is used
	-i <version>: override automatically set database version
	-d <name>: database name to dump, option can be given multiple times, if not set all databases are dumped
	-e <name>: exclude database from dump, option can be given multiple times, if not set non are excluded
	-u <db user>: default is 'postgres'
	-h <db host>: default is none
	-p <db port>: default port is '5432'
	-l <db password>: default password is empty
	-r: use redhat base paths instead of debian
	-a: use amazon base paths instead of debian
	-L <log path>: where to put the dump log file, if not set tries to use PostgreSQL log folder
	EOT
}

TEST=0; # if set to 1 will run script without doing anything
SSLMODE='disable';
GLOBALS=1; # if set to 0 will not dump globals
# in days, keeps KEEP+1 files, today + KEEP days before
# or keep number of files if CLEAN_NUMBER is true, then it can't be 0
KEEP=3;
CLEAN_NUMBER=0;
BACKUPDIR='';
DB_VERSION='';
DB_USER='';
DB_PASSWD='';
DB_HOST='';
DB_PORT='';
EXCLUDE=''; # space separated list of database names
INCLUDE=''; # space seperated list of database names
BC='/usr/bin/bc';
PRE_RUN_CLEAN_UP=0;
SET_IDENT=0;
PORT_REGEX="^[0-9]{4,5}$";
OPTARG_REGEX="^-";
# log path
LOG_PATH='';
# base path for PostgreSQL binary
DBPATH_BASE='';
# defaults
_BACKUPDIR='/mnt/backup/db_dumps_fc/';
_DB_VERSION=$(pgv=$(pg_dump --version| grep "pg_dump" | cut -d " " -f 3); if [[ $(echo "${pgv}" | cut -d "." -f 1) -ge 10 ]]; then echo "${pgv}" | cut -d "." -f 1; else echo "${pgv}" | cut -d "." -f 1,2; fi );
_DB_USER='postgres';
_DB_PASSWD='';
_DB_HOST='';
_DB_PORT=5432;
_EXCLUDE=''; # space separated list of database names
_INCLUDE=''; # space seperated list of database names
REDHAT=0;
AMAZON=0;
CONN_DB_HOST='';
ERROR=0;

# set options
while getopts ":ctsgnk:b:i:d:e:u:h:p:l:L:ram" opt; do
	# pre test for unfilled
	if [ "${opt}" = ":" ] || [[ "${OPTARG-}" =~ ${OPTARG_REGEX} ]]; then
		if [ "${opt}" = ":" ]; then
			CHECK_OPT=${OPTARG};
		else
			CHECK_OPT=${opt};
		fi;
		case ${CHECK_OPT} in
			k)
				echo "-k needs a number";
				ERROR=1;
				;;
			b)
				echo "-b needs a path";
				ERROR=1;
				;;
			i)
				echo "-i needs an ident";
				ERROR=1;
				;;
			u)
				echo "-u needs a user name";
				ERROR=1;
				;;
			h)
				echo "-h needs a host name";
				ERROR=1;
				;;
			p)
				echo "-p needs a port number";
				ERROR=1;
				;;
			l)
				echo "-l needs a login password";
				ERROR=1;
				;;
			d)
				echo "-d needs a database name";
				ERROR=1;
				;;
			e)
				echo "-e needs a database name";
				ERROR=1;
				;;
			L)
				echo "-L needs a log path";
				ERROR=1;
				;;
		esac
	fi;
	# set options
	case ${opt} in
		t|test)
			TEST=1;
			;;
		g|globals)
			GLOBALS=0;
			;;
		c|clean-up-before)
			PRE_RUN_CLEAN_UP=1;
			;;
		s|sslmode)
			SSLMODE=enable;
			;;
		k|keep)
			KEEP=${OPTARG};
			;;
		n|number-keep)
			CLEAN_NUMBER=1;
			;;
		b|backuppath)
			if [ -z "${BACKUPDIR}" ]; then
				BACKUPDIR="${OPTARG}";
			fi;
			;;
		i|ident)
			if [ -z "${DB_VERSION}" ]; then
				DB_VERSION=${OPTARG};
				SET_IDENT=1;
			fi;
			;;
		u|user)
			if [ -z "${DB_USER}" ]; then
				DB_USER=${OPTARG};
			fi;
			;;
		h|hostname)
			if [ -z "${DB_HOST}" ]; then
				DB_HOST=${OPTARG};
			fi;
			;;
		p|port)
			if [ -z "${DB_PORT}" ]; then
				DB_PORT=${OPTARG};
			fi;
			;;
		l|login)
			if [ -z "${DB_PASSWD}" ]; then
				DB_PASSWD=${OPTARG};
			fi;
			;;
		d|database)
			if [ ! -z "${INCLUDE}" ]; then
				INCLUDE=${INCLUDE}" ";
			fi;
			INCLUDE=${INCLUDE}${OPTARG};
			;;
		e|exclude)
			if [ ! -z "${EXCLUDE}" ]; then
				EXCLUDE=${EXCLUDE}" ";
			fi;
			EXCLUDE=${EXCLUDE}${OPTARG};
			;;
		r|redhat)
			REDHAT=1;
			;;
		a|amazon)
			AMAZON=1;
			;;
		L|logpath)
			if [ ! -z "{$LOG_PATH}" ]; then
				LOG_PATH="${OPTARG}";
			fi;
			;;
		m|manual)
			usage;
			exit 0;
			;;
		:)
			echo "Option -$OPTARG requires an argument."
			;;
		\?)
			echo -e "\n Option does not exist: ${OPTARG}\n";
			usage;
			exit 1;
			;;
	esac;
done;

if [ ${ERROR} -eq 1 ]; then
	exit 0;
fi;

if [ "${REDHAT}" -eq 1 ] && [ "${AMAZON}" -eq 1 ]; then
	echo "You cannot set the -a and -r flag at the same time";
	exit 0;
fi;

# if we have numeric keep and keep number is set to 0 abort
if [ ${CLEAN_NUMBER} -eq 1 ] && [ ${KEEP} -lt 1 ]; then
	echo "If keep in numbers is on, keep must be at least 1 or higher";
	exit 0;
fi;

# set the defaults
for name in BACKUPDIR DB_VERSION DB_USER DB_PASSWD DB_HOST DB_PORT EXCLUDE INCLUDE; do
	# assign it to the real name if the real name is empty
	if [ -z "${!name}" ]; then
		# add the _ for the default name
		default="_"${name};
		eval ${name}=\${!default};
	fi;
done;

# check base paths depending on installation and set log file
if [ "${REDHAT}" -eq 1 ]; then
	# Redhat base path (for non official ones would be '/usr/pgsql-'
	# This is also for Amazon NEWER (after 9.6)
	PG_BASE_PATH="/usr/pgsql-";
	# I assume that as default
	LOG_PATH="/var/lib/pgsql/${DB_VERSION}/data/log/";
elif [ "${AMAZON}" -eq 1 ]; then
	# only older 9.6 or before
	PG_BASE_PATH="/usr/lib64/pgsql";
	# LOG PATH, will be attached to DB VERSION
	LOG_PATH="/var/lib/pgsql${DB_VERSION}/data/pg_log";
else
	# Debian base path
	PG_BASE_PATH="/usr/lib/postgresql/";
	LOG_PATH="/var/log/postgresql/";
fi;

# setup log before everything else
LOG="${LOG_PATH}pg_db_dump_file.log";
# if we cannot write to the log file abort
if [[ -f "${LOG}" && ! -w "${LOG}" ]] || [[ ! -f "${LOG}" && ! -w "${LOG_PATH}" ]]; then
	echo "Cannot write to ${LOG} or create a new log file in ${LOG_PATH}";
	exit;
fi;
# log to file and also write to stdout
exec &> >(tee -a "${LOG}");

# check DB port is valid number
if ! [[ "${DB_PORT}" =~ ${PORT_REGEX} ]]; then
	echo "The port needs to be a valid number: ${_port}";
	exit 0;
fi;

# check if we have the 'bc' command available or not
if [ -f "${BC}" ]; then
	BC_OK=1;
else
	BC_OK=0;
fi;

# if DB_HOST is set, we need to add -h to the command line
# if nothing is set, DB_HOST is set to local so we know this is a "port" connection for later automatic restore
if [ -z "${DB_HOST}" ]; then
	DB_HOST='local';
else
	CONN_DB_HOST='-h '${DB_HOST};
fi;

# set the binaries we need
PG_PATH=${PG_BASE_PATH}${DB_VERSION}'/bin/';
PG_PSQL=${PG_PATH}'psql';
PG_DUMP=${PG_PATH}'pg_dump';
PG_DUMPALL=${PG_PATH}'pg_dumpall';
DB_TYPE='pgsql';
db='';

# core abort if no core files found
if [ ! -f ${PG_PSQL} ] || [ ! -f ${PG_DUMP} ] || [ ! -f ${PG_DUMPALL} ]; then
	echo "One of the core binaries (psql, pg_dump, pg_dumpall) could not be found.";
	echo "Search Path: ${PG_PATH}";
	echo "Perhaps manual ident set with -i is necessary";
	echo "Backup aborted";
	exit 0;
fi;

if [ ! -d ${BACKUPDIR} ] ; then
	if ! mkdir ${BACKUPDIR} ; then
		echo "Cannot create backup directory: ${BACKUPDIR}"
		exit 0;
	fi
fi
# check if we can write into that folder
touch ${BACKUPDIR}/tmpfile || echo "[!] touch failed";
if [ ! -f ${BACKUPDIR}/tmpfile ]; then
	echo "Cannot write to ${BACKUPDIR}";
	exit 0;
else
	rm -f ${BACKUPDIR}/tmpfile;
fi;
# if backupdir is "." rewrite to pwd
if [ "${BACKUPDIR}" == '.' ]; then
	BACKUPDIR=$(pwd);
fi;
# check if we can connect to template1 table, if not we abort here
connect=$(${PG_PSQL} -U "${DB_USER}" ${CONN_DB_HOST} -p ${DB_PORT} -d template1 -t -A -F "," -X -q -c "SELECT datname FROM pg_catalog.pg_database WHERE datname = 'template1';") || echo "[!] pgsql connect error";
if [ "${connect}" != "template1" ]; then
	echo "Failed to connect to template1 with user '${DB_USER}' at host '${DB_HOST}' on port '${DB_PORT}'";
	exit 0;
fi;

# if we have an ident override set, set a different DUMP VERSION here than the automatic one
if [ "${SET_IDENT}" -eq 1 ]; then
	DUMP_DB_VERSION=$(pgv=$(${PG_PATH}/pg_dump --version| grep "pg_dump" | cut -d " " -f 3); if [[ $(echo "${pgv}" | cut -d "." -f 1) -ge 10 ]]; then echo "${pgv}" | cut -d "." -f 1; else echo "${pgv}" | cut -d "." -f 1,2; fi );
else
	DUMP_DB_VERSION=${DB_VERSION};
fi;

# turn of ssl
# comment line out, if SSL connection is wanted
export PGSSLMODE=${SSLMODE};

# METHOD: convert_time
# PARAMS: timestamp in seconds or with milliseconds (nnnn.nnnn)
# RETURN: formated string with human readable time (d/h/m/s)
# CALL  : var=$(convert_time $timestamp);
# DESC  : converts a timestamp or a timestamp with float milliseconds to a human readable format
#         output is in days/hours/minutes/seconds
function convert_time
{
	timestamp=${1};
	# round to four digits for ms
	timestamp=$(printf "%1.4f" $timestamp);
	# get the ms part and remove any leading 0
	ms=$(echo ${timestamp} | cut -d "." -f 2 | sed -e 's/^0*//');
	timestamp=$(echo ${timestamp} | cut -d "." -f 1);
	timegroups=(86400 3600 60 1); # day, hour, min, sec
	timenames=("d" "h" "m" "s"); # day, hour, min, sec
	output=( );
	time_string='';
	for timeslice in ${timegroups[@]}; do
		# floor for the division, push to output
		if [ ${BC_OK} -eq 1 ]; then
			output[${#output[*]}]=$(echo "${timestamp}/${timeslice}" | bc);
			timestamp=$(echo "${timestamp}%${timeslice}" | bc);
		else
			output[${#output[*]}]=$(awk "BEGIN {printf \"%d\", ${timestamp}/${timeslice}}");
			timestamp=$(awk "BEGIN {printf \"%d\", ${timestamp}%${timeslice}}");
		fi;
	done;

	for ((i=0; i<${#output[@]}; i++)); do
		if [ ${output[$i]} -gt 0 ] || [ ! -z "$time_string" ]; then
			if [ ! -z "${time_string}" ]; then
				time_string=${time_string}" ";
			fi;
			time_string=${time_string}${output[$i]}${timenames[$i]};
		fi;
	done;
	# milliseconds must be filled, but we also check that they are non "nan" string
	# that can appear in the original value
	if [ ! -z ${ms} ] && [ "${ms}" != "nan" ]; then
		if [ ${ms} -gt 0 ]; then
			time_string=${time_string}" "${ms}"ms";
		fi;
	fi;
	# just in case the time is 0
	if [ -z "${time_string}" ]; then
		time_string="0s";
	fi;
	echo -n "${time_string}";
}

# METHOD: convert_bytes
# PARAMS: size in bytes
# RETURN: human readable byte data in TB/GB/MB/KB/etc
# CALL  : size=$(convert_bytes $bytes);
# DESC  : converts bytes into human readable format with 2 decimals
function convert_bytes
{
	bytes=${1};
	# use awk to calc it
	echo -n $(echo ${bytes} | awk 'function human(x) {
		 s=" B  KB MB GB TB EB PB YB ZB"
		 while (x>=1024 && length(s)>1)
			   {x/=1024; s=substr(s,4)}
		 s=substr(s,1,4)
		 xf=(s==" B  ")?"%d   ":"%.2f"
		 return sprintf( xf"%s\n", x, s)
	}
	{gsub(/^[0-9]+/, human($1)); print}');
}

# METHOD: get_dump_file_name
# PARAMS: none
# RETURN: dump file name (echo)
# CALL  : var=$(get_dump_file_name);
# DESC  : function for getting the correct dump file
function get_dump_file_name
{
	# set base search for the files
	sequence=*;
	if [ ${db} ]; then
		db_name=${db}"."${owner}"."${encoding}".";
	else
		db_name="pg_globals."${DB_USER}".NONE.";
	fi;
	file=${BACKUPDIR}"/"${db_name}${DB_TYPE}"-"${DUMP_DB_VERSION}"_"${DB_HOST}"_"${DB_PORT}"_"$(date +%Y%m%d)"_"$(date +%H%M)"_"${sequence}".c.sql";
	seq='';
	# we need to find the next sequence number
	for i in $(ls -1 ${file} 2>/dev/null); do
		# get the last sequence and cut any leading 0 so we can run +1 on it
		seq=$(echo $i | cut -d "." -f 3 | cut -d "_" -f 4 | sed -e "s/^0//g");
	done;
	if [ ! -z ${seq} ]; then
		# add +1 and if < 10 prefix with 0
		let seq=${seq}+1;
		if [ ${seq} -lt 10 ]; then
			sequence="0"${seq};
		else
			sequence=${seq};
		fi;
	else
		sequence="01";
	fi;
	# now build correct file name
	filename=${BACKUPDIR}"/"${db_name}${DB_TYPE}"-"${DUMP_DB_VERSION}"_"${DB_HOST}"_"${DB_PORT}"_"$(date +%Y%m%d)"_"$(date +%H%M)"_"${sequence}".c.sql";
	echo "${filename}";
}

# METHOD: get_dump_databases
# PARAMS: none
# RETURN: none
# CALLS : var=$(get_dump_databases)
# DESC  : this is needd only for clean up run if the clean up is run before
#         the actually database dump
#         fills up the global search names aray
function get_dump_databases
{
	search_names=();
	if [ ${GLOBALS} -eq 1 ]; then
		search_names+=("pg_globals.*");
	fi;
	for owner_db in $(${PG_PSQL} -U ${DB_USER} ${CONN_DB_HOST} -p ${DB_PORT} -d template1 -t -A -F "," -X -q -c "SELECT pg_catalog.pg_get_userbyid(datdba) AS owner, datname, pg_catalog.pg_encoding_to_char(encoding) FROM pg_catalog.pg_database WHERE datname "\!"~ 'template(0|1)';"); do
		db=$(echo ${owner_db} | cut -d "," -f 2);
		# check if we exclude this db
		exclude=0;
		include=0;
		for excl_db in ${EXCLUDE}; do
			if [ "${db}" = "${excl_db}" ]; then
				exclude=1;
				break;
			fi;
		done;
		if [ ! -z "${INCLUDE}" ]; then
			for incl_db in ${INCLUDE}; do
				if [ "${db}" = "${incl_db}" ]; then
					include=1;
					break;
				fi;
			done;
		else
			include=1;
		fi;
		if [ ${exclude} -eq 0 ] && [ ${include} -eq 1 ]; then
			search_names+=("${db}.*");
		fi;
	done;
}

# METHOD: clean_up
# PARAMS: none
# RETURN: none
# CALL  : $(clean_up);
# DESC  : checks for older files than given keep time/amount and removes them
function clean_up
{
	if [ -d ${BACKUPDIR} ]; then
		if [ ${CLEAN_NUMBER} -eq 0 ]; then
			echo "Cleanup older than ${KEEP} days backup in ${BACKUPDIR}";
		else
			echo "Cleanup up, keep only ${KEEP} backups in ${BACKUPDIR}";
			# if we run clean before backup, we need to clean up +1
			# so if we keep one, we must remove all data before running new
			if [ ${PRE_RUN_CLEAN_UP} -eq 1 ]; then
				let KEEP=${KEEP}-1;
			fi;
		fi;
		# build the find string based on the search names patter
		find_string='';
		for name in "${search_names[@]}"; do
			# for not number based, we build the find string here
			# else we do the delete here already
			if [ ${CLEAN_NUMBER} -eq 0 ]; then
				if [ ! -z "${find_string}" ]; then
					find_string=${find_string}' -o ';
				fi;
				find_string=${find_string}"-mtime +${KEEP} -name "${name}${DB_TYPE}*.sql" -type f -delete -print";
				echo "- Remove old backups for '${name}'";
			else
				# if we do number based delete of old data, but only if the number of
				# files is bigger than the keep number or equal if we do PRE_RUN_CLEAN_UP
				# this can be error, but we allow it -> script should not abort here
				# note we have a wildcard in the name, so we can't put that into ""
				count=$(ls "${BACKUPDIR}/"${name}${DB_TYPE}*.sql 2>/dev/null | wc -l) || true;
				if [ ${PRE_RUN_CLEAN_UP} -eq 1 ]; then
					let count=${count}+1;
				fi;
				if [ ${count} -gt ${KEEP} ]; then
					# calculate the amount to delete
					# eg if we want to keep 1, and we have 3 files then we need to delete 2
					# keep is always +1 (include the to backup count).
					# count is +1 if we do a pre-run cleanup
					# grouped by db name, db type
					let TO_DELETE=${count}-${KEEP};
					echo "- Remove old backups for '${name}', found ${count}, will delete ${TO_DELETE}";
					if [ ${TEST} -eq 0 ]; then
						ls -tr "${BACKUPDIR}/"${name}${DB_TYPE}*.sql 2>/dev/null | head -n ${TO_DELETE} | xargs rm;
					else
						echo "ls -tr ${BACKUPDIR}/${name}${DB_TYPE}*.sql 2>/dev/null | head -n ${TO_DELETE} | xargs rm";
					fi;
				fi;
			fi;
		done;
		# if we do find (day based) delete of old data
		if [ ${CLEAN_NUMBER} -eq 0 ]; then
			if [ ${TEST} -eq 0 ]; then
				find ${BACKUPDIR} ${find_string};
			else
				echo "find ${BACKUPDIR} ${find_string}";
			fi;
		fi;
	fi
}

if [ ! -z "${DB_PASSWD}" ]; then
	export PGPASSWORD=${DB_PASSWD};
fi;
START=$(date "+%s");
echo "=======================================================================>";
printf "Starting at %s\n" "$(date '+%Y-%m-%d %H:%M:%S')";
echo "Target dump directory is: ${BACKUPDIR}";
echo "Keep ${KEEP} backups";
# if flag is set, do pre run clean up
if [ ${PRE_RUN_CLEAN_UP} -eq 1 ]; then
	get_dump_databases;
	clean_up;
fi;
echo "Backing up databases:";
# reset search name list for actual dump
search_names=();
# dump globals
if [ ${GLOBALS} -eq 1 ]; then
	echo -e -n "+ Dumping globals ... "
	# reset any previous set db name from deletes so the correct global file name is set
	db='';
	filename=$(get_dump_file_name);
	search_names+=("pg_globals.*"); # this is used for the find/delete part
	if [ ${TEST} -eq 0 ]; then
		${PG_DUMPALL} -U ${DB_USER} ${CONN_DB_HOST} -p ${DB_PORT} --globals-only > "${filename}";
	else
		echo "${PG_DUMPALL} -U ${DB_USER} ${CONN_DB_HOST} -p ${DB_PORT} --globals-only > ${filename}";
	fi;
	echo "done";
else
	echo "- Skip dumping globals";
fi;

echo -n "(+) Dump databases: ";
if [ -z "${INCLUDE}" ]; then
	echo "All";
else
	echo ${INCLUDE};
fi;
echo -n "(-) Exclude databases: ";
if [ -z "${EXCLUDE}" ]; then
	echo "None";
else
	echo ${EXCLUDE};
fi;

filesize_sum=0;
for owner_db in $(${PG_PSQL} -U ${DB_USER} ${CONN_DB_HOST} -p ${DB_PORT} -d template1 -t -A -F "," -X -q -c "SELECT pg_catalog.pg_get_userbyid(datdba) AS owner, datname, pg_catalog.pg_encoding_to_char(encoding) AS encoding FROM pg_catalog.pg_database WHERE datname "\!"~ 'template(0|1)' ORDER BY datname;"); do
	# get the user who owns the DB too
	owner=$(echo ${owner_db} | cut -d "," -f 1);
	db=$(echo ${owner_db} | cut -d "," -f 2);
	encoding=$(echo ${owner_db} | cut -d "," -f 3);
	# check if we exclude this db
	exclude=0;
	include=0;
	for excl_db in ${EXCLUDE}; do
		if [ "${db}" = "${excl_db}" ]; then
			exclude=1;
			break;
		fi;
	done;
	if [ ! -z "${INCLUDE}" ]; then
		for incl_db in ${INCLUDE}; do
			if [ "${db}" = "${incl_db}" ]; then
				include=1;
				break;
			fi;
		done;
	else
		include=1;
	fi;
	if [ ${exclude} -eq 0 ] && [ ${include} -eq 1 ]; then
		printf "+ Dumping database: %35s ... " "${db}";
		filename=$(get_dump_file_name);
		search_names+=("${db}.*");
		SUBSTART=$(date "+%s");
		if [ ${TEST} -eq 0 ]; then
			${PG_DUMP} -U ${DB_USER} ${CONN_DB_HOST} -p ${DB_PORT} -c --format=c ${db} > "${filename}";
		else
			echo "${PG_DUMP} -U ${DB_USER} ${CONN_DB_HOST} -p ${DB_PORT} -c --format=c ${db} > ${filename}";
		fi;
		# get the file size for the dumped file and convert it to a human readable format
		filesize=0;
		if [ -f "${filename}" ]; then
			filesize=$(wc -c "${filename}" | cut -f 1 -d ' ');
			filesize_sum=$[$filesize+$filesize_sum];
		fi;
		DURATION=$[$(date "+%s")-${SUBSTART}];
		printf "done (%s and %s)\n" "$(convert_time ${DURATION})" "$(convert_bytes ${filesize})";
	else
		printf -- "- Exclude database: %35s\n" "${db}";
	fi;
done
printf "Backup ended at %s\n" "$(date '+%Y-%m-%d %H:%M:%S')";
if [ ! -z "${DB_PASSWD}" ]; then
	unset DB_PASSWD;
fi;

if [ ${PRE_RUN_CLEAN_UP} -eq 0 ]; then
	clean_up;
fi;

DURATION=$[$(date "+%s")-${START}];
printf "Cleanup ended at %s\n" "$(date '+%Y-%m-%d %H:%M:%S')";
printf "Finished backup in %s with %s\n" "$(convert_time ${DURATION})" "$(convert_bytes ${filesize_sum})";

## END

#!/usr/bin/env bash
# backup each mysql database into a different file, rather than one big file
# as with --all-databases - will make restores easier
# based on:
# http://soniahamilton.wordpress.com/2005/11/16/backup-multiple-databases-into-separate-files/
# http://mysqlpreacher.com/wordpress/2010/08/dumping-ddl-mysqldump-tables-stored-procedures-events-triggers-separately/

# Functions
function verbose {
    if [ "$VERBOSE" ]; then
        if [ "$2" ]; then
            echo -en $1;
        else
            echo -e $1;
        fi
    fi
}

# Initial Variable definitions
DATE=`date +'%Y%m%d'`
# MYSQL_USER must have following global privileges:
# SELECT, SHOW DATABASES, LOCK TABLES, EVENT, TRIGGER, SHOW VIEW
MYSQL_USER="mysqldump"
MYSQL_HOST="localhost"
MYSQL_CHARSET="utf8"
OUTPUT_DIR="."
OUTPUT_FILE="mysqldumps.tar.gz"
DUMPS_DIRNAME="mysqldumps_${DATE}"

# Parse commandline options first
while :
do
    case "$1" in
        -c | --default-charset)
            if [ -z "$2" ]; then echo "Error: Default character set not specified" >&2; exit 1; fi
            MYSQL_CHARSET=$2
            shift 2
            ;;
        -d | --output-directory)
            if [ -z "$2" ]; then echo "Error: Output directory not specified" >&2; exit 1; fi
            OUTPUT_DIR=$2
            shift 2
            ;;
        -h | --host)
            if [ -z "$2" ]; then echo "Error: MySQL server hostname not specified" >&2; exit 1; fi
            MYSQL_HOST=$2
            shift 2
            ;;
        -f | --output-file)
            if [ -z "$2" ]; then echo "Error: Output filename not specified" >&2; exit 1; fi
            OUTPUT_FILE=$2
            shift 2
            ;;
        -p | --pass)
            if [ -z "$2" ]; then echo "Error: MySQL password not specified" >&2; exit 1; fi
            MYSQL_PASSWORD=$2
            shift 2
            ;;
        -s | --skip-delete-previous)
            SKIP_DELETE_PREVIOUS="skip delete previous"
            shift
            ;;
        -u | --user)
            if [ -z "$2" ]; then echo "Error: MySQL username not specified" >&2; exit 1; fi
            MYSQL_USER=$2
            shift 2
            ;;
        -v | --verbose)
            VERBOSE="verbose"
            shift
            ;;
        -t | --skip-tarballing)
            SKIP_TARBALLING="skip tarballing"
            shift
            ;;
#        --) # End of all options
#            shift
#            break;
        -*)
            echo "Error: Unknown option: $1" >&2
            exit 1
            ;;
        *)  # No more options
            break
            ;;
    esac
done

# Checking if required parameters are present and valid
if [ ! -d "$OUTPUT_DIR" ]; then echo "Error: Specified output is not a directory" >&2; exit 1; fi
if [ ! -w "$OUTPUT_DIR" ]; then echo "Error: Output directory is not writable" >&2; exit 1; fi
if [ -e "${OUTPUT_DIR}/${OUTPUT_FILE}" ]; then echo "Error: Specified output file already exists" >&2; exit 1; fi
if [ -z "$MYSQL_PASSWORD" ]; then echo "Error: MySQL password not provided or empty" >&2; exit 1; fi
if [ -e "${OUTPUT_DIR}/${DUMPS_DIRNAME}" ]; then echo "Error: Output directory already contains a file/folder with the same name as temporary folder required: ${OUTPUT_DIR}/$DUMPS_DIRNAME" >&2; exit 1; fi

# OK, let's roll
verbose "START\n" 1

STATIC_PARAMS="--default-character-set=$MYSQL_CHARSET --host=$MYSQL_HOST --user=$MYSQL_USER --password=$MYSQL_PASSWORD"
MYSQLDUMP="/usr/local/bin/mysqldump"
MYSQL="/usr/local/bin/mysql"

STAT="/usr/bin/stat"
TAR="/usr/bin/tar"

if [ "$SKIP_DELETE_PREVIOUS" ]; then
    verbose "NOT deleting any old backups..."
else
    verbose "Deleting any old backups..."
    rm -fv ${OUTPUT_DIR}/mysqldump*.tar.gz
fi

verbose "\nCreating temporary folder: ${DUMPS_DIRNAME}."
mkdir ${OUTPUT_DIR}/${DUMPS_DIRNAME}

verbose "\nRetrieving list of all databases... " 1
aDatabases=( $($MYSQL $STATIC_PARAMS -N -e "SHOW DATABASES;" | grep -Ev "(test|information_schema|mysql|performance_schema|phpmyadmin)") )
verbose "done."
verbose "Found" ${#aDatabases[@]}" valid database(s).\n"

sDatabases=${aDatabases[*]}

verbose "Beginning dump process..."
for db in $sDatabases; do
    verbose "- dumping '${db}'... " 1
    SECONDS=0
    # dumping database tables structure
    $MYSQLDUMP $STATIC_PARAMS \
        --no-data \
        --opt \
        --set-charset \
        --skip-triggers \
        --databases $db > ${OUTPUT_DIR}/${DUMPS_DIRNAME}/$db.1-DB+TABLES+VIEWS.sql

    # dumping data
    $MYSQLDUMP $STATIC_PARAMS \
        --force \
        --hex-blob \
        --no-create-db \
        --no-create-info \
        --opt \
        --skip-triggers \
        --databases $db > ${OUTPUT_DIR}/${DUMPS_DIRNAME}/$db.2-DATA.sql

    # dumping triggers
    $MYSQLDUMP $STATIC_PARAMS \
        --no-create-db \
        --no-create-info \
        --no-data \
        --skip-opt --create-options \
        --triggers \
        --databases $db > ${OUTPUT_DIR}/${DUMPS_DIRNAME}/$db.3-TRIGGERS.sql

    # dumping events (works in MySQL 5.1+)
    $MYSQLDUMP $STATIC_PARAMS \
        --events \
        --no-create-db \
        --no-create-info \
        --no-data \
        --skip-opt --create-options \
        --skip-triggers \
        --databases $db > ${OUTPUT_DIR}/${DUMPS_DIRNAME}/$db.4-EVENTS.sql

    # dumping routines
    $MYSQLDUMP $STATIC_PARAMS \
        --no-create-db \
        --no-create-info \
        --no-data \
        --routines \
        --skip-opt --create-options \
        --skip-triggers \
        --databases $db > ${OUTPUT_DIR}/${DUMPS_DIRNAME}/$db.5-ROUTINES.sql

    verbose "done in" $SECONDS "second(s);"
done

verbose "- dumping PRIVILEGES... " 1
SECONDS=0
$MYSQL $STATIC_PARAMS -B -N -e "SELECT DISTINCT CONCAT(
        'SHOW GRANTS FOR ''', user, '''@''', host, ''';'
        ) AS query FROM mysql.user" | \
        $MYSQL $STATIC_PARAMS | \
        sed 's/\(GRANT .*\)/\1;/;s/^\(Grants for .*\)/## \1 ##/;/##/{x;p;x;}' > "${OUTPUT_DIR}/${DUMPS_DIRNAME}/PRIVILEGES.sql"
verbose "done in" $SECONDS "second(s)."
verbose "Dump process completed."

if [ "$SKIP_TARBALLING" ]; then
    verbose "\nSkipping tarballing sql dumps"
else
    verbose "\nTarballing all sql dumps... " 1
    cd ${OUTPUT_DIR}
    SECONDS=0
    $TAR cfz ${OUTPUT_FILE} ${DUMPS_DIRNAME}
    verbose "done in" $SECONDS "second(s)."

    output_file_size=`$STAT -f %z $OUTPUT_FILE`

    verbose "\nDeleting sql files... " 1
    rm -fvR ${OUTPUT_DIR}/${DUMPS_DIRNAME}
    verbose "done."

    verbose "\nFinal dump file: ${OUTPUT_DIR}/${OUTPUT_FILE} (${output_file_size} bytes).\n"
fi

verbose "END."

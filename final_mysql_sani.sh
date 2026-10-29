#!/bin/bash

export PATH=/usr/lib/jvm/jdk-21.0.7-oracle-x64/bin/:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

MYSQL_DATA_DIR=/var/lib/mysql/alertdriving
MYSQL_USER=mysql
MYSQL_GROUP=mysql
MYSQLD_SAFE=/usr/bin/mysqld_safe
MYSQL_INIT_SCRIPT=/etc/init.d/mysql

SOURCE_DUMP_DIR=/opt/data/mysql/backup

SANI_DUMP_DIR=/opt/mysql_full_dump_sanitized
SANI_DUMP_TGZ=/opt/mysql_full_dump_sanitized.tgz
SANI_DUMP_OLD_TAR=/opt/mysql_full_dump_sanitized.tar
SANI_DUMP_OLD_TAR_GZ=/opt/mysql_full_dump_sanitized.tar.gz

DESTINATION=/opt/data_dump_files_after_sanitization
STRUCTURES_SQL=${DESTINATION}/database_structures.sql
TRIGGERS_SQL=${DESTINATION}/database_triggers.sql
USERS_PERMS_SQL=${DESTINATION}/database_users_permissions.sql

me=$(basename "$0")
filename="${me%.*}"
LOG_DIR=/root
Logfile=${LOG_DIR}/${filename}.log
ERROR_LOG=${LOG_DIR}/${filename}_errors.log
XTRABACKUP_BACKUP_LOG=${LOG_DIR}/xtrabackup_backup.log
XTRABACKUP_PREPARE_LOG=${LOG_DIR}/xtrabackup_prepare.log

MD5_TMP=/opt/mysql-files-md5.txt
MD5_TMP_CLEANED=/opt/mysql-files-md5_paths_removed.txt
MD5_FINAL=${SANI_DUMP_DIR}/mysql-files-md5.txt

MOVE_TGZ_TO_SHAREME=0
SHAREME_DIR=/shareMe
SHAREME_DUMP_TGZ=${SHAREME_DIR}/mysql_full_dump_sanitized.tgz

SHIP_TO_REMOTE=0
REMOTE_USER=root
REMOTE_HOST=10.150.5.63
REMOTE_DUMP_DIR=/dump/mysql_full_dump_sanitized
SSH_TARGET="${REMOTE_USER}@${REMOTE_HOST}"
SCP_CIPHER=aes128-ctr

HOST=localhost
MYSQL_ROOT_USER=root
# Change this one value to set the sanitized password everywhere supported.
# Use an ASCII value without a single quote or backslash.
SANITIZED_PASSWORD='Password#1'
MYSQL_ROOT_PASS="sonic_root"

DATABASES="uam fd_lms AD_Main ALERT-CORE dams_schema keycloak scorm shopopencart fd_col fd_demo fd_dw fd_inroads ir_inroads_api ad_vault"
DBOPTIONS="--single-transaction --skip-add-locks --skip-comments"

EMAIL_SANI_SALT='capoptix_sani_2026'
EMAIL_SANI_DOMAIN='adt.com'
EMAIL_SANI_SCHEMAS="'uam','fd_lms','AD_Main','ALERT-CORE','dams_schema','keycloak','scorm','ad_vault','fd_dw','shopopencart','fd_demo'"
# The local part is a 16-character Base37 encoding of the low-order Base37
# digits of the salted SHA-256 digest. The complete sanitized address is
# therefore 16 + 1 + the domain length (24 characters for @adt.com).
EMAIL_SANI_HASH_LENGTH=16
EMAIL_SANI_MIN_HASH_LENGTH=15
EMAIL_SANI_HASH_MODULUS=12337511914217166362274241 # 37^16
EMAIL_HASH_FUNCTION_SCHEMA='uam'
EMAIL_HASH_FUNCTION_NAME='sanitize_email_base37'
EMAIL_HASH_FUNCTION_INSTALLED=0

# Large email tables to keep and sanitize with indexed row-range batches.
EMAIL_FAST_BATCH_TABLES=(
	"fd_lms.aperture_email_log"
)
EMAIL_SANI_ROW_BATCH_SIZE=2000000
EMAIL_SANI_MIN_ROW_BATCH_SIZE=10000
EMAIL_SANI_BATCH_RETRIES=5
OPTIMIZE_APERTURE_EMAIL_INDEXES=1

# full: restore and sanitize everything.
# resume-aperture: keep the current restored database, finish only the
# interrupted aperture email work, then run final cleanup and export.
RUN_MODE="${RUN_MODE:-full}"
APERTURE_INDEXES_TEMPORARILY_REMOVED=0

# Add tables that must be emptied before sanitization in schema.table format.
# Leave the array empty when no additional tables need to be truncated.
# Example:
# TRUNCATE_TABLES=(
# 	"fd_lms.table_one"
# 	"AD_Main.table_two"
# )
TRUNCATE_TABLES=(
	# This table contained roughly 29 million rows and caused the multi-day
	# name/email sanitization workload. TRUNCATE preserves its structure.
	"fd_dw.rosterfile"

	"ad_vault.vault"
	"ad_vault.vault_content"
	"ad_vault.request_log"
	"ad_vault.response_log"

	"AD_Main.ErrorLog"
	"AD_Main.ErrorLogIndex"
	"AD_Main.audit_UserInformation"
	"fd_col.logs"
	"fd_col.statistics"
	"fd_dw.errorlog"
	"fd_dw.logs"
	"fd_dw.rosterfile_company_seasonal_allocation_maps"
	"fd_dw.rosterfile_conf"
	"fd_dw.rosterfile_process"
	"fd_dw.statistics"
	"fd_dw.usage_report_job_sftp"
	"fd_dw.usage_report_job_comments"
	"fd_dw.usage_report_job_cot_tmp"
	"fd_dw.usage_report_job_log"
	"fd_dw.usage_report_job_secondary"
	"fd_dw.usage_report_job_secondary_comments"
	"fd_dw.usage_report_job_secondary_log"
	"fd_inroads.fdi_event_log_transformation"
	"fd_inroads.fdi_infraction_free_streak_reset_transactions"
	"fd_inroads.fdi_provider_event_log"
	"fd_inroads.fdi_provider_event_log_all"
	"fd_inroads.fdi_provider_to_consumer_event_records"
	"fd_inroads.fdi_provider_to_consumer_user"
	"fd_inroads.fdi_provider_to_consumer_user_history"
	"fd_inroads.fdi_provider_vehicle_list"
	"fd_inroads.fdi_provider_vehicle_list_history"
	"fd_inroads.fdi_provider_vehicle_trip"
	"fd_inroads.fdi_user_infraction_free_days_count"
	"fd_inroads.fdi_vehicle_trip_daily_summary"
	"fd_inroads.inroads_api_call_log"
	"fd_lms.adp_process"
	"fd_lms.adp_process_consume"
	"fd_lms.adp_process_consume_error"
	"fd_lms.adp_process_extract"
	"fd_lms.adp_process_finalize"
	"fd_lms.adp_process_transform"
	"fd_lms.adp_credentials"
	"fd_lms.fd_Activity_Competency_Seq_log"
	"fd_lms.fd_Fix_Year1Year2IssueDate_1MONTH_UPDATE_log"
	"fd_lms.fd_company_lms_callback_user_event"
	"fd_lms.fd_company_lms_callback_user_event_metadata"
	"fd_lms.fd_company_lms_log"
	"fd_lms.fd_company_lms_log_file"
	"fd_lms.fd_company_lms_log_file_map"
	"fd_lms.fd_company_report"
	"fd_lms.fd_company_report_ftp"
	"fd_lms.fd_company_successfactors"
	"fd_lms.ir_device_notification_callback_log"
	"fd_lms.ir_device_notification_queue"
	"fd_lms.ir_device_notification_queue_resources"
	"fd_lms.ir_user_devices"
	"ir_inroads_api.request_log"
	"ir_inroads_api.response_log"
	"ir_inroads_api.sync_runs"
)

# Personal-data sanitization settings. Names, addresses, and text-based phone
# values use SHA2(CONCAT(salt, LOWER(TRIM(value))), 256). These settings and
# updates remain separate from the email settings and SANITIZE_EMAILS function.
PII_SANI_SALT='capoptix_pii_sani_2026'
PII_SANI_SCHEMAS="'uam','fd_lms','AD_Main','ALERT-CORE','dams_schema','keycloak','scorm','ad_vault','fd_dw','shopopencart','fd_demo'"
# Store the first 32 hexadecimal characters of the SHA-256 result.
# A column shorter than this automatically receives only what it can hold.
PII_SANI_HASH_LENGTH=32
# Numeric phone columns cannot store a SHA string. Store zero in those columns;
# for numeric types this is equivalent to a value written as 0000000000.
NUMERIC_PHONE_SANI_VALUE=0
# Number of distinct source values handled by each committed update.
PII_SANI_BATCH_SIZE=10000
PII_SANI_MIN_BATCH_SIZE=1

# Every nonblank password-style text column receives this exact value.
PASSWORD_SANI_VALUE="${SANITIZED_PASSWORD}"
PASSWORD_SANI_SCHEMAS="${PII_SANI_SCHEMAS}"

# Required sanitized SFTP configuration for fd_lms.fd_lms_extra_services.
FD_LMS_EXTRA_SERVICES_CREDENTIALS='{"directory":"testfolder/out","url":"sftp.fleetdefense.com","port":"22","username":"adfiletransfer","password":"T56#jk72"}'
FD_COMPANY_REPORT_FTP_HOST='sftp.fleetdefense.com'

# QA and DEV use the same sanitized callback endpoint.
CALLBACK_URL='https://fd.fleetdefense.com/test/callback_response.php'
FD_DEMO_PASSWORD_HASH='$2y$10$.PhktZkr8W2QUGzaeQ9pzOqcQQHqGAnWUCWZnseEtbzm6hJ4rCdhK'
FD_DEMO_REMEMBER_TOKEN='SnzuuBEtsKCJvLdXtLPYgT6WK1LYtMKnMLI2q8R8pUVwF5u0jcBGKJoRo4Yl'

XTRABACKUP_DECOMPRESS_PAR=12
XTRABACKUP_BACKUP_PAR=4
XTRABACKUP_OPEN_FILES_LIMIT=65535
ARCHIVE_PAR=4
EMAIL_SANI_MAX_PAR=1

DELETE_SOURCE_BACKUP=0

set -uo pipefail

# Keep long-running work alive if the launching SSH terminal disconnects.
trap '' HUP

SCRIPT_START_EPOCH=$(date +%s)

if [ -z "${SANITIZED_PASSWORD}" ]; then
	echo "SANITIZED_PASSWORD must not be empty" >&2
	exit 1
fi

case "${SANITIZED_PASSWORD}" in
	*"'"*|*\\*)
		echo "SANITIZED_PASSWORD must not contain a single quote or backslash" >&2
		exit 1
		;;
esac

ulimit -n "${XTRABACKUP_OPEN_FILES_LIMIT}" || true

log() {
	echo "$(date) - $*" | tee -a "$Logfile"
}

ERRORmsg() {
	echo "$(date) - ERROR: $*" | tee -a "$Logfile" "$ERROR_LOG"
}

REPORT_TOTAL_ELAPSED() {
	local rc=$?
	local elapsed days hours minutes seconds
	trap - EXIT
	if [ "${APERTURE_INDEXES_TEMPORARILY_REMOVED}" -eq 1 ]; then
		ERRORmsg "Exit detected while aperture secondary indexes may be absent; attempting repair"
		if ! RESTORE_APERTURE_EMAIL_SECONDARY_INDEXES; then
			ERRORmsg "Emergency aperture index repair failed"
			rc=1
		fi
	fi
	if [ "${EMAIL_HASH_FUNCTION_INSTALLED}" -eq 1 ]; then
		ERRORmsg "Exit detected while the temporary email hash function is installed; attempting cleanup"
		if ! DROP_EMAIL_HASH_FUNCTION; then
			ERRORmsg "Emergency email hash function cleanup failed"
			rc=1
		fi
	fi
	elapsed=$(($(date +%s) - SCRIPT_START_EPOCH))
	days=$((elapsed / 86400))
	hours=$(((elapsed % 86400) / 3600))
	minutes=$(((elapsed % 3600) / 60))
	seconds=$((elapsed % 60))
	log "Script finished at: $(date)"
	log "Total elapsed time: ${days}d ${hours}h ${minutes}m ${seconds}s (${elapsed} seconds); exit status: ${rc}"
	exit "$rc"
}

trap REPORT_TOTAL_ELAPSED EXIT

run_mysql() {
	local output status
	output=$(mysql -h"${HOST}" -u"${MYSQL_ROOT_USER}" -p"${MYSQL_ROOT_PASS}" -e "$1" 2>&1)
	status=$?
	printf '%s\n' "${output}" >> "$Logfile"
	if [ "${status}" -ne 0 ]; then
		ERRORmsg "MySQL command failed with exit status ${status}: ${output//$'\n'/ | }"
	fi
	return "${status}"
}

CAPTURE_MYSQL_DIAGNOSTICS() {
	{
		echo "$(date) - Diagnostic snapshot"
		echo "Disk space:"
		df -h "${MYSQL_DATA_DIR}" 2>&1
		echo "MySQL variables:"
		mysql -h"${HOST}" -u"${MYSQL_ROOT_USER}" -p"${MYSQL_ROOT_PASS}" -N -B -e "
			SHOW VARIABLES WHERE Variable_name IN
			('datadir','innodb_buffer_pool_size','innodb_log_file_size','innodb_lock_wait_timeout','tmpdir');
			SHOW GLOBAL STATUS WHERE Variable_name IN
			('Threads_connected','Threads_running','Innodb_row_lock_current_waits','Innodb_row_lock_time','Innodb_row_lock_waits');
			SHOW FULL PROCESSLIST;
			SHOW ENGINE INNODB STATUS;
		" 2>&1
		echo "End diagnostic snapshot"
	} >> "${ERROR_LOG}"
}

TRUNCATE_ALERT_CORE_AUDIT_TABLES() {
	local tables table fail=0
	tables=$(mysql -h"${HOST}" -u"${MYSQL_ROOT_USER}" -p"${MYSQL_ROOT_PASS}" -N -B -e "
		SELECT TABLE_NAME
		FROM information_schema.TABLES
		WHERE TABLE_SCHEMA='ALERT-CORE'
		  AND TABLE_TYPE='BASE TABLE'
		  AND TABLE_NAME LIKE 'audit\\_%';
	" 2>>"$Logfile") || {
		ERRORmsg "Could not discover ALERT-CORE audit tables"
		return 1
	}

	if [ -z "${tables}" ]; then
		log "No ALERT-CORE audit_* base tables found."
		return 0
	fi

	while IFS= read -r table; do
		[ -z "${table}" ] && continue
		if [[ ! "${table}" =~ ^[A-Za-z0-9_-]+$ ]]; then
			ERRORmsg "Unsafe ALERT-CORE audit table name returned: ${table}"
			fail=1
			continue
		fi
		log "Truncating ALERT-CORE.${table}"
		run_mysql "SET FOREIGN_KEY_CHECKS=0; TRUNCATE TABLE \`ALERT-CORE\`.\`${table}\`; SET FOREIGN_KEY_CHECKS=1;" || fail=1
	done <<< "${tables}"

	return "${fail}"
}

APPLY_REVIEW_RESEEDS() {
	log "Applying SanitizationReview table reseeds..."

	run_mysql "
		INSERT INTO fd_dw.rosterfile_conf
			(companyid, ftpgetdir, ftpputdir, localdir, version, frequent, status, managerloginid, defaultlicenseid, internal_rest_token_user, internal_rest_token_password, notes, managerpassword, seasonal_allocations)
		VALUES
			(0, 'DONOT_DELETE', 'DONOT_DELETE', '0', 'EXP', NULL, 0, 'N/A', NULL, 'ad-api-user1', '${SANITIZED_PASSWORD}', 'https://alertdriving.atlassian.net/browse/AP-2840', NULL, 0);

		INSERT INTO fd_dw.usage_report_job_sftp
			(id, companyid, host, \`user\`, password, port, \`path\`)
		VALUES
			(2, 2193, '10.150.8.25', 'aperfiletransfer', '${SANITIZED_PASSWORD}', 22, 'from_adfiletransfer//2193//out'),
			(3, 1, '10.150.8.25', 'aperfiletransfer', '${SANITIZED_PASSWORD}', 22, '/q2reports/out');

		INSERT INTO fd_lms.adp_credentials
			(id, set_id, service_name, url, api_key, host, port, \`user\`, password, token, \`key\`, secret, ppkpath, status, created, updated)
		VALUES
			(1, 1, 'ETLWithTelematicsGoMotiveApi', 'https://fd.fleetdefense.com/test/adp/gomotive/driver_performance_events.php', 'cfXTppJM25', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2024-11-06 15:36:08', '2026-08-12 19:06:08'),
			(3, 1, 'ETLWithTelematicsGoMotiveApi', 'https://fd.fleetdefense.com/test/adp/gomotive/speeding_events.php', 'cfXTppJM25', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2025-09-02 16:02:44', '2026-08-12 19:06:08');

		INSERT INTO fd_lms.fd_company_report_ftp
			(id, company_id, ftp_host, ftp_user, ftp_password, ftp_port, sftp)
		VALUES
			(5, 282, 'sftp.fleetdefense.com', 'adfiletransfer', '${SANITIZED_PASSWORD}', 22, 1);

		INSERT INTO fd_lms.fd_company_report
			(id, company_id, course_id, report_type_id, ftp_id, remote_folder_path)
		VALUES
			(1, 291, 585, 1, 5, '/to_adfiletransfer'),
			(10, 817, 904, 1, 5, '/to_adfiletransfer'),
			(11, 282, 366, 1, 5, '/to_adfiletransfer');

		INSERT INTO fd_lms.fd_company_successfactors
			(id, companyid, lms_userid, clientid, secret, clientsecret_hash, lms_company, usertype, resourcetype, timecreated, timemodified)
		VALUES
			(1, 1521, 'tigadmin', 'msaworldwi', '${SANITIZED_PASSWORD}', '${SANITIZED_PASSWORD}', 'msaworldwi', 'admin', 'learning_public_api', 20201105174632, NULL);
	" || {
		ERRORmsg "One or more SanitizationReview reseed statements failed"
		return 1
	}

	log "Applying SanitizationReview table reseeds DONE"
	return 0
}

APPLY_REVIEW_FINAL_UPDATES() {
	local column_lengths name_max email_max scorm_code_max
	local name_single_hash_length name_multi_hash_length
	local email_single_hash_length email_multi_hash_length email_suffix_length email_split_multi
	local scorm_code_hash_length scorm_collision_count

	column_lengths=$(mysql -h"${HOST}" -u"${MYSQL_ROOT_USER}" -p"${MYSQL_ROOT_PASS}" -N -B -e "
		SELECT
			IFNULL(MAX(CASE WHEN COLUMN_NAME='user_name' THEN CHARACTER_MAXIMUM_LENGTH END),0),
			IFNULL(MAX(CASE WHEN COLUMN_NAME='user_email' THEN CHARACTER_MAXIMUM_LENGTH END),0),
			(SELECT IFNULL(CHARACTER_MAXIMUM_LENGTH,0)
			 FROM information_schema.COLUMNS
			 WHERE TABLE_SCHEMA='scorm' AND TABLE_NAME='USER' AND COLUMN_NAME='USER_LMS_CODE'
			 LIMIT 1)
		FROM information_schema.COLUMNS
		WHERE TABLE_SCHEMA='fd_col'
		  AND TABLE_NAME='current_sum_compliance_data'
		  AND COLUMN_NAME IN ('user_name','user_email');
	" 2>>"$Logfile") || {
		ERRORmsg "Could not read fd_col current_sum column sizes"
		return 1
	}
	IFS=$'\t' read -r name_max email_max scorm_code_max <<< "${column_lengths}"
	if [[ ! "${name_max}" =~ ^[0-9]+$ || ! "${email_max}" =~ ^[0-9]+$ ||
	      ! "${scorm_code_max}" =~ ^[0-9]+$ || "${name_max}" -lt 3 ||
	      "${email_max}" -lt 3 || "${scorm_code_max}" -lt 1 ]]; then
		ERRORmsg "Invalid review column sizes: fd_col.user_name=${name_max}, fd_col.user_email=${email_max}, scorm.USER_LMS_CODE=${scorm_code_max}"
		return 1
	fi

	name_single_hash_length=${PII_SANI_HASH_LENGTH}
	[ "${name_single_hash_length}" -gt "${name_max}" ] && name_single_hash_length=${name_max}
	name_multi_hash_length=$(((name_max - 1) / 2))
	[ "${name_multi_hash_length}" -gt "${PII_SANI_HASH_LENGTH}" ] && name_multi_hash_length=${PII_SANI_HASH_LENGTH}

	email_suffix_length=$((${#EMAIL_SANI_DOMAIN} + 1))
	email_single_hash_length=$((email_max - email_suffix_length))
	[ "${email_single_hash_length}" -gt "${EMAIL_SANI_HASH_LENGTH}" ] && email_single_hash_length=${EMAIL_SANI_HASH_LENGTH}
	email_multi_hash_length=$((((email_max - 1) / 2) - email_suffix_length))
	[ "${email_multi_hash_length}" -gt "${EMAIL_SANI_HASH_LENGTH}" ] && email_multi_hash_length=${EMAIL_SANI_HASH_LENGTH}
	if [ "${email_single_hash_length}" -lt "${EMAIL_SANI_MIN_HASH_LENGTH}" ]; then
		ERRORmsg "fd_col.current_sum_compliance_data.user_email (${email_max}) cannot fit one sanitized email with at least ${EMAIL_SANI_MIN_HASH_LENGTH} Base37 characters and @${EMAIL_SANI_DOMAIN}"
		return 1
	fi
	if [ "${email_multi_hash_length}" -lt "${EMAIL_SANI_MIN_HASH_LENGTH}" ]; then
		email_split_multi=0
		log "WARNING: fd_col user_email is only ${email_max} characters and cannot safely hold two sanitized addresses. Comma-separated source values will be normalized and collapsed into one ${email_single_hash_length}-character Base37 address at @${EMAIL_SANI_DOMAIN}."
	else
		email_split_multi=1
		if [ "${email_single_hash_length}" -lt "${EMAIL_SANI_HASH_LENGTH}" ] || \
		   [ "${email_multi_hash_length}" -lt "${EMAIL_SANI_HASH_LENGTH}" ]; then
			log "WARNING: fd_col user_email is only ${email_max} characters; values will use ${email_single_hash_length} Base37 characters for a single address and ${email_multi_hash_length} per comma-separated address."
		fi
	fi

	scorm_code_hash_length=${scorm_code_max}
	[ "${scorm_code_hash_length}" -gt 64 ] && scorm_code_hash_length=64
	if [ "${scorm_code_hash_length}" -lt 16 ]; then
		ERRORmsg "scorm.USER.USER_LMS_CODE (${scorm_code_max}) is too short for collision-resistant sanitization"
		return 1
	fi

	scorm_collision_count=$(mysql -h"${HOST}" -u"${MYSQL_ROOT_USER}" -p"${MYSQL_ROOT_PASS}" -N -B -e "
		SELECT COUNT(*)
		FROM (
			SELECT CUSTOMER_ID,
			       LEFT(SHA2(CONCAT('${PII_SANI_SALT}',LOWER(TRIM(USER_LMS_CODE))),256),${scorm_code_hash_length}) AS sanitized_code
			FROM scorm.\`USER\`
			WHERE USER_LMS_CODE IS NOT NULL AND TRIM(USER_LMS_CODE)!=''
			GROUP BY CUSTOMER_ID, sanitized_code
			HAVING COUNT(*) > 1
		) collisions;
	" 2>>"$Logfile") || {
		ERRORmsg "Could not perform scorm USER_LMS_CODE collision precheck"
		return 1
	}
	if [[ ! "${scorm_collision_count}" =~ ^[0-9]+$ || "${scorm_collision_count}" -ne 0 ]]; then
		ERRORmsg "scorm USER_LMS_CODE collision precheck found ${scorm_collision_count} duplicate customer/hash combinations"
		return 1
	fi

	log "Safe hash lengths: fd_col name single=${name_single_hash_length}, name comma-part=${name_multi_hash_length}, email single=${email_single_hash_length}, email split-multi=${email_split_multi}, email comma-part=${email_multi_hash_length}; scorm USER_LMS_CODE=${scorm_code_hash_length}."

	log "Applying SanitizationReview final updates for QA/DEV..."
	run_mysql "
		START TRANSACTION;

		UPDATE \`ALERT-CORE\`.user_addresses
		SET city='North York',
			state_province='Ontario',
			zip_postalcode='M3C 3R8',
			country='Canada';

		UPDATE fd_col.current_sum_compliance_data
		SET user_name=CASE
				WHEN user_name IS NULL OR TRIM(user_name)='' THEN user_name
				WHEN user_name LIKE '%,%' THEN CONCAT(
					LEFT(SHA2(CONCAT('${PII_SANI_SALT}',LOWER(TRIM(SUBSTRING_INDEX(user_name,',',1)))),256),${name_multi_hash_length}),
					',',
					LEFT(SHA2(CONCAT('${PII_SANI_SALT}',LOWER(TRIM(SUBSTRING(user_name,LOCATE(',',user_name)+1)))),256),${name_multi_hash_length})
				)
				ELSE LEFT(SHA2(CONCAT('${PII_SANI_SALT}',LOWER(TRIM(user_name))),256),${name_single_hash_length})
			END,
			user_email=CASE
				WHEN user_email IS NULL OR TRIM(user_email)='' THEN user_email
				WHEN user_email LIKE '%,%'
				 AND ${email_split_multi} = 1
				 AND CHAR_LENGTH(TRIM(SUBSTRING_INDEX(user_email,',',1))) = ${email_multi_hash_length} + ${email_suffix_length}
				 AND RIGHT(TRIM(SUBSTRING_INDEX(user_email,',',1)),${email_suffix_length}) = '@${EMAIL_SANI_DOMAIN}'
				 AND LEFT(TRIM(SUBSTRING_INDEX(user_email,',',1)),${email_multi_hash_length}) NOT REGEXP '[^a-z0-9_]'
				 AND CHAR_LENGTH(TRIM(SUBSTRING(user_email,LOCATE(',',user_email)+1))) = ${email_multi_hash_length} + ${email_suffix_length}
				 AND RIGHT(TRIM(SUBSTRING(user_email,LOCATE(',',user_email)+1)),${email_suffix_length}) = '@${EMAIL_SANI_DOMAIN}'
				 AND LEFT(TRIM(SUBSTRING(user_email,LOCATE(',',user_email)+1)),${email_multi_hash_length}) NOT REGEXP '[^a-z0-9_]'
				THEN user_email
				WHEN user_email LIKE '%,%' AND ${email_split_multi} = 1 THEN CONCAT(
					LEFT(${EMAIL_HASH_FUNCTION_SCHEMA}.${EMAIL_HASH_FUNCTION_NAME}(SUBSTRING_INDEX(user_email,',',1)),${email_multi_hash_length}),'@${EMAIL_SANI_DOMAIN}',
					',',
					LEFT(${EMAIL_HASH_FUNCTION_SCHEMA}.${EMAIL_HASH_FUNCTION_NAME}(SUBSTRING(user_email,LOCATE(',',user_email)+1)),${email_multi_hash_length}),'@${EMAIL_SANI_DOMAIN}'
				)
				WHEN user_email LIKE '%,%' THEN CONCAT(
					LEFT(
						${EMAIL_HASH_FUNCTION_SCHEMA}.${EMAIL_HASH_FUNCTION_NAME}(
							CONCAT(
								TRIM(SUBSTRING_INDEX(user_email,',',1)),
								',',
								TRIM(SUBSTRING(user_email,LOCATE(',',user_email)+1))
							)
						),
						${email_single_hash_length}
					),
					'@${EMAIL_SANI_DOMAIN}'
				)
				WHEN CHAR_LENGTH(TRIM(user_email)) = ${email_single_hash_length} + ${email_suffix_length}
				 AND RIGHT(TRIM(user_email),${email_suffix_length}) = '@${EMAIL_SANI_DOMAIN}'
				 AND LEFT(TRIM(user_email),${email_single_hash_length}) NOT REGEXP '[^a-z0-9_]'
				THEN user_email
				ELSE CONCAT(LEFT(${EMAIL_HASH_FUNCTION_SCHEMA}.${EMAIL_HASH_FUNCTION_NAME}(user_email),${email_single_hash_length}),'@${EMAIL_SANI_DOMAIN}')
			END;

		UPDATE fd_demo.users
		SET name=LEFT(SHA2(CONCAT('${PII_SANI_SALT}',LOWER(TRIM(name))),256),${PII_SANI_HASH_LENGTH})
		WHERE name IS NOT NULL AND TRIM(name)!='';
		UPDATE fd_demo.users
		SET password='${FD_DEMO_PASSWORD_HASH}',
			remember_token='${FD_DEMO_REMEMBER_TOKEN}';

		UPDATE fd_dw.HPlicenseid
		SET name=LEFT(SHA2(CONCAT('${PII_SANI_SALT}',LOWER(TRIM(name))),256),${PII_SANI_HASH_LENGTH})
		WHERE name IS NOT NULL AND TRIM(name)!='';
		UPDATE fd_dw.HPlicenseid
		SET displayname=LEFT(SHA2(CONCAT('${PII_SANI_SALT}',LOWER(TRIM(displayname))),256),${PII_SANI_HASH_LENGTH})
		WHERE displayname IS NOT NULL AND TRIM(displayname)!='';
		UPDATE fd_dw.usage_report_job SET status=0;

		UPDATE fd_lms.fd_company_lms_tokens SET url='${CALLBACK_URL}';
		UPDATE fd_lms.fd_company_lms_endpoints
		SET url='${CALLBACK_URL}',
			\`key\`='AnyThingWillWork',
			secret='AnyThingWillWork'
		WHERE url IS NOT NULL AND url<>'';

		UPDATE scorm.\`USER\`
		SET USER_LMS_CODE=LEFT(SHA2(CONCAT('${PII_SANI_SALT}',LOWER(TRIM(USER_LMS_CODE))),256),${scorm_code_hash_length})
		WHERE USER_LMS_CODE IS NOT NULL AND TRIM(USER_LMS_CODE)!='';

		COMMIT;
	" || {
		ERRORmsg "One or more SanitizationReview final updates failed"
		return 1
	}

	log "Applying SanitizationReview final updates DONE"
	return 0
}

STOPPING_MYSQL_SERVER() {
	log "Stopping MySQL Database..."
	service mysql stop >> "$Logfile" 2>&1 || true
	sleep 15

	killall -v mysqld >> "$Logfile" 2>&1 || true
	sleep 15

	log "Deleting all MySQL files from ${MYSQL_DATA_DIR}..."
	rm -rf "${MYSQL_DATA_DIR}"
	mkdir -p "${MYSQL_DATA_DIR}"
	sync

	df -h | tee -a "$Logfile"
	return 0
}

COPYING_MYSQL_FILES() {
	if [ ! -d "${SOURCE_DUMP_DIR}" ] || [ -z "$(ls -A "${SOURCE_DUMP_DIR}" 2>/dev/null)" ]; then
		ERRORmsg "SOURCE_DUMP_DIR is empty: ${SOURCE_DUMP_DIR}"
		return 1
	fi

	chmod 700 "${SOURCE_DUMP_DIR}"

	log "Decompressing MySQL files..."
	xtrabackup \
		--parallel="${XTRABACKUP_DECOMPRESS_PAR}" \
		--decompress \
		--remove-original \
		--target-dir="${SOURCE_DUMP_DIR}/" \
		2>&1 | tee -a "$Logfile"

	if [ "${PIPESTATUS[0]}" -ne 0 ]; then
		ERRORmsg "xtrabackup decompress failed"
		return 1
	fi

	if [ ! -f "${SOURCE_DUMP_DIR}/xtrabackup_checkpoints" ]; then
		ERRORmsg "Invalid source backup. Missing ${SOURCE_DUMP_DIR}/xtrabackup_checkpoints"
		return 1
	fi

	log "Copying MySQL files from ${SOURCE_DUMP_DIR} to ${MYSQL_DATA_DIR}..."
	cp -a "${SOURCE_DUMP_DIR}/"* "${MYSQL_DATA_DIR}/"

	log "Preparing restored MySQL dump..."
	xtrabackup --prepare --target-dir="${MYSQL_DATA_DIR}" 2>&1 | tee -a "$Logfile"

	if [ "${PIPESTATUS[0]}" -ne 0 ]; then
		ERRORmsg "xtrabackup prepare restore failed"
		return 1
	fi

	du -sh "${MYSQL_DATA_DIR}" | tee -a "$Logfile"

	log "Fixing permissions on MySQL DATA DIR..."
	find "${MYSQL_DATA_DIR}" -type d -exec chmod 700 {} \;
	find "${MYSQL_DATA_DIR}" -type f -exec chmod 660 {} \;
	chmod 750 "${MYSQL_DATA_DIR}"
	chown -R "${MYSQL_USER}:${MYSQL_GROUP}" "${MYSQL_DATA_DIR}/"

	return 0
}

STARTING_MYSQL_SERVER() {
	log "Starting MySQL using mysqld_safe --skip-grant-tables..."
	"${MYSQLD_SAFE}" --skip-grant-tables >> "$Logfile" 2>&1 &
	sleep 25

	log "Running mysql_upgrade..."
	mysql_upgrade >> "$Logfile" 2>&1 || true
	sleep 20

	service mysql stop >> "$Logfile" 2>&1 || true
	sleep 20
	killall -v mysqld >> "$Logfile" 2>&1 || true
	sleep 10

	log "Starting MySQL again using --skip-grant-tables to reset root password..."
	"${MYSQLD_SAFE}" --skip-grant-tables >> "$Logfile" 2>&1 &
	sleep 25

	mysql mysql -e "
		UPDATE mysql.user
		SET authentication_string=PASSWORD('${MYSQL_ROOT_PASS}')
		WHERE User='root';
		FLUSH PRIVILEGES;
	" >> "$Logfile" 2>&1 || true

	sleep 10

	service mysql stop >> "$Logfile" 2>&1 || true
	sleep 20
	killall -v mysqld >> "$Logfile" 2>&1 || true
	sleep 10

	log "Starting MySQL normally..."
	"${MYSQL_INIT_SCRIPT}" start >> "$Logfile" 2>&1
	sleep 30

	df -h | tee -a "$Logfile"
	return 0
}

CHECK_SQL_AUTHENTICATION() {
	log "Checking MySQL connection to ${HOST}..."

	DBS=$(mysql -h"${HOST}" -u"${MYSQL_ROOT_USER}" -p"${MYSQL_ROOT_PASS}" -e "SHOW DATABASES;" 2>>"$Logfile" || true)

	if [[ -z "$DBS" ]]; then
		ERRORmsg "MySQL connection failed"
		return 1
	fi

	return 0
}

TRUNCATE_CONFIGURED_TABLES() {
	if [ "${#TRUNCATE_TABLES[@]}" -eq 0 ]; then
		log "No additional tables configured for truncation."
		return 0
	fi

	local entry
	local schema
	local table
	local table_type
	local has_rows
	local configured=0
	local fail=0

	for entry in "${TRUNCATE_TABLES[@]}"; do
		# Ignore empty entries and entries containing whitespace only.
		entry="${entry#"${entry%%[![:space:]]*}"}"
		entry="${entry%"${entry##*[![:space:]]}"}"
		[ -z "${entry}" ] && continue

		if [ "${configured}" -eq 0 ]; then
			log "Checking configured tables before truncation..."
		fi
		configured=1

		if [[ ! "${entry}" =~ ^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]]; then
			ERRORmsg "Invalid TRUNCATE_TABLES entry '${entry}'. Expected schema.table."
			fail=1
			continue
		fi

		schema="${entry%%.*}"
		table="${entry#*.}"

		table_type=$(mysql -h"${HOST}" -u"${MYSQL_ROOT_USER}" -p"${MYSQL_ROOT_PASS}" -N -B -e "
			SELECT TABLE_TYPE
			FROM information_schema.TABLES
			WHERE TABLE_SCHEMA='${schema}'
			  AND TABLE_NAME='${table}'
			LIMIT 1;
		" 2>>"$Logfile") || {
			ERRORmsg "Could not validate configured table ${entry}"
			fail=1
			continue
		}

		if [ "${table_type}" != "BASE TABLE" ]; then
			if [ "${entry}" = "ir_inroads_api.sync_runs" ]; then
				if [ -z "${table_type}" ]; then
					log "WARNING: Skipping optional review target ${entry}; it is absent in this backup."
				else
					log "WARNING: Skipping ${entry}; object type is ${table_type} and views do not store rows to truncate."
				fi
				continue
			fi
			ERRORmsg "Configured truncate target is not a base table: ${entry} (type: ${table_type:-ABSENT})"
			fail=1
			continue
		fi

		has_rows=$(mysql -h"${HOST}" -u"${MYSQL_ROOT_USER}" -p"${MYSQL_ROOT_PASS}" -N -B -e "
			SELECT EXISTS(
				SELECT 1
				FROM \`${schema}\`.\`${table}\`
				LIMIT 1
			);
		" 2>>"$Logfile") || {
			ERRORmsg "Could not check whether ${entry} is empty"
			fail=1
			continue
		}

		if [ "${has_rows}" = "0" ]; then
			log "Skipping ${entry}; table is already empty."
			continue
		fi

		log "Truncating ${entry}"
		if ! run_mysql "
			SET FOREIGN_KEY_CHECKS=0;
			TRUNCATE TABLE \`${schema}\`.\`${table}\`;
			SET FOREIGN_KEY_CHECKS=1;
		"; then
			ERRORmsg "Failed to truncate ${entry}"
			fail=1
		fi
	done

	if [ "${configured}" -eq 0 ]; then
		log "No additional tables configured for truncation."
		return 0
	fi

	if [ "${fail}" -ne 0 ]; then
		ERRORmsg "One or more configured tables failed to truncate"
		return 1
	fi

	log "Configured table truncation DONE"
	return 0
}

SANITIZE_TEXT_COLUMN_IN_BATCHES() {
	local schema="$1"
	local table="$2"
	local column="$3"
	local max_length="$4"
	local value_type="$5"
	local batch_size="${PII_SANI_BATCH_SIZE}"
	local helper_table="__pii_sani_map_$$"
	local output
	local affected
	local total=0
	local mysql_status
	local max_id
	local batch_start=0
	local batch_end

	output=$(mysql -h"${HOST}" -u"${MYSQL_ROOT_USER}" -p"${MYSQL_ROOT_PASS}" -N -B -e "
		DROP TABLE IF EXISTS \`${schema}\`.\`${helper_table}\`;

		CREATE TABLE \`${schema}\`.\`${helper_table}\` (
			id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
			source_hash BINARY(32) NOT NULL,
			sanitized_value VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
			PRIMARY KEY (id),
			UNIQUE KEY source_hash_unique (source_hash)
		) ENGINE=InnoDB;

		INSERT INTO \`${schema}\`.\`${helper_table}\` (source_hash, sanitized_value)
		SELECT DISTINCT
			UNHEX(SHA2(LOWER(TRIM(\`${column}\`)), 256)),
			LEFT(
				SHA2(CONCAT('${PII_SANI_SALT}', LOWER(TRIM(\`${column}\`))), 256),
				LEAST(${max_length}, ${PII_SANI_HASH_LENGTH})
			)
		FROM \`${schema}\`.\`${table}\`
		WHERE \`${column}\` IS NOT NULL
		  AND TRIM(\`${column}\`) != '';

		SELECT COALESCE(MAX(id), 0)
		FROM \`${schema}\`.\`${helper_table}\`;
	" 2>&1)
	mysql_status=$?

	printf '%s\n' "${output}" >> "$Logfile"

	if [ "${mysql_status}" -ne 0 ]; then
		ERRORmsg "Could not build sanitization batches for ${schema}.${table}.${column}"
		run_mysql "DROP TABLE IF EXISTS \`${schema}\`.\`${helper_table}\`;" || true
		return 1
	fi

	max_id=$(printf '%s\n' "${output}" | awk '/^[0-9]+$/ { value=$0 } END { print value }')
	if [[ ! "${max_id}" =~ ^[0-9]+$ ]]; then
		ERRORmsg "Could not read sanitization batch count for ${schema}.${table}.${column}"
		run_mysql "DROP TABLE IF EXISTS \`${schema}\`.\`${helper_table}\`;" || true
		return 1
	fi

	if [ "${max_id}" -eq 0 ]; then
		log "Skipping ${schema}.${table}.${column}; it contains only NULL or blank values."
		run_mysql "DROP TABLE IF EXISTS \`${schema}\`.\`${helper_table}\`;" || true
		return 0
	fi

	while [ "${batch_start}" -lt "${max_id}" ]; do
		batch_end=$((batch_start + batch_size))

		output=$(mysql -h"${HOST}" -u"${MYSQL_ROOT_USER}" -p"${MYSQL_ROOT_PASS}" -N -B -e "
			SET SESSION sql_log_bin=0;
			SET SESSION lock_wait_timeout=3600;
			SET SESSION innodb_lock_wait_timeout=3600;

			UPDATE \`${schema}\`.\`${table}\` AS pii_target
			JOIN \`${schema}\`.\`${helper_table}\` AS pii_map
			  ON UNHEX(SHA2(LOWER(TRIM(pii_target.\`${column}\`)), 256)) = pii_map.source_hash
			SET pii_target.\`${column}\` = pii_map.sanitized_value
			WHERE pii_map.id > ${batch_start}
			  AND pii_map.id <= ${batch_end};

			SELECT ROW_COUNT();
		" 2>&1)
		mysql_status=$?

		printf '%s\n' "${output}" >> "$Logfile"

		if [ "${mysql_status}" -ne 0 ]; then
			if [[ "${output}" == *"ERROR 1206"* ]] && [ "${batch_size}" -gt "${PII_SANI_MIN_BATCH_SIZE}" ]; then
				batch_size=$((batch_size / 2))
				if [ "${batch_size}" -lt "${PII_SANI_MIN_BATCH_SIZE}" ]; then
					batch_size="${PII_SANI_MIN_BATCH_SIZE}"
				fi

				log "Lock limit reached for ${schema}.${table}.${column}; retrying with batch size ${batch_size}."
				continue
			fi

			ERRORmsg "FAILED ${value_type} update: ${schema}.${table}.${column}"
			run_mysql "DROP TABLE IF EXISTS \`${schema}\`.\`${helper_table}\`;" || true
			return 1
		fi

		affected=$(printf '%s\n' "${output}" | awk '/^[0-9]+$/ { value=$0 } END { print value }')
		if [[ ! "${affected}" =~ ^[0-9]+$ ]]; then
			ERRORmsg "Could not read affected-row count for ${schema}.${table}.${column}"
			run_mysql "DROP TABLE IF EXISTS \`${schema}\`.\`${helper_table}\`;" || true
			return 1
		fi

		total=$((total + affected))
		batch_start="${batch_end}"
		log "Sanitized ${total} rows in ${schema}.${table}.${column} (latest batch: ${affected})."
	done

	if ! run_mysql "DROP TABLE IF EXISTS \`${schema}\`.\`${helper_table}\`;"; then
		ERRORmsg "Could not remove temporary sanitization map ${schema}.${helper_table}"
		return 1
	fi

	return 0
}

SANITIZE_PERSONAL_DATA() {
	log "Sanitizing first names, last names, addresses, and phone numbers..."

	local hash_cols
	local phone_cols
	local schema
	local table
	local column
	local max_length
	local data_type
	local fail=0

	hash_cols=$(mysql -h"${HOST}" -u"${MYSQL_ROOT_USER}" -p"${MYSQL_ROOT_PASS}" -N -B -e "
		SELECT
			c.TABLE_SCHEMA,
			c.TABLE_NAME,
			c.COLUMN_NAME,
			COALESCE(c.CHARACTER_MAXIMUM_LENGTH, 64)
		FROM information_schema.COLUMNS c
		JOIN information_schema.TABLES t
		  ON t.TABLE_SCHEMA = c.TABLE_SCHEMA
		 AND t.TABLE_NAME = c.TABLE_NAME
		WHERE c.TABLE_SCHEMA IN (${PII_SANI_SCHEMAS})
		  AND t.TABLE_TYPE = 'BASE TABLE'
		  AND c.DATA_TYPE IN ('varchar','char','text','tinytext','mediumtext','longtext')
		  AND (
			LOWER(c.COLUMN_NAME) IN (
				'first_name','firstname','first-name','fname','given_name','givenname',
				'last_name','lastname','last-name','lname','surname','family_name','familyname'
			)
			OR (
				LOWER(c.COLUMN_NAME) LIKE '%address%'
				AND LOWER(c.COLUMN_NAME) NOT LIKE '%email%'
				AND LOWER(c.COLUMN_NAME) NOT LIKE '%address_format%'
				AND LOWER(c.COLUMN_NAME) NOT IN (
					'ip_address','ipaddress','mac_address','macaddress',
					'web_address','url_address','wallet_address'
				)
			)
		  );
	" 2>>"$Logfile") || {
		ERRORmsg "Failed to discover name/address columns"
		return 1
	}

	if [ -z "${hash_cols}" ]; then
		log "No first-name, last-name, or address columns found."
	else
		while IFS=$'\t' read -r schema table column max_length; do
			[ -z "${schema}" ] && continue

			log "Hashing ${schema}.${table}.${column}"

			if ! SANITIZE_TEXT_COLUMN_IN_BATCHES \
				"${schema}" "${table}" "${column}" "${max_length}" "name/address"; then
				fail=1
			fi
		done <<< "${hash_cols}"
	fi

	phone_cols=$(mysql -h"${HOST}" -u"${MYSQL_ROOT_USER}" -p"${MYSQL_ROOT_PASS}" -N -B -e "
		SELECT
			c.TABLE_SCHEMA,
			c.TABLE_NAME,
			c.COLUMN_NAME,
			COALESCE(c.CHARACTER_MAXIMUM_LENGTH, 0),
			c.DATA_TYPE
		FROM information_schema.COLUMNS c
		JOIN information_schema.TABLES t
		  ON t.TABLE_SCHEMA = c.TABLE_SCHEMA
		 AND t.TABLE_NAME = c.TABLE_NAME
		WHERE c.TABLE_SCHEMA IN (${PII_SANI_SCHEMAS})
		  AND t.TABLE_TYPE = 'BASE TABLE'
		  AND (
			LOWER(c.COLUMN_NAME) LIKE '%phone%'
			OR LOWER(c.COLUMN_NAME) LIKE '%telephone%'
			OR LOWER(c.COLUMN_NAME) IN (
				'mobile','mobile_number','mobilenumber',
				'cell','cell_number','cellnumber'
			)
		  )
		  AND LOWER(c.COLUMN_NAME) NOT LIKE '%phone_verified%'
		  AND LOWER(c.COLUMN_NAME) NOT LIKE '%phone_enabled%'
		  AND LOWER(c.COLUMN_NAME) NOT LIKE '%phonetic%'
		  AND LOWER(c.COLUMN_NAME) NOT IN ('phonecode','phone_code','telephone_code')
		  AND c.DATA_TYPE IN (
			'varchar','char','text','tinytext','mediumtext','longtext',
			'tinyint','smallint','mediumint','int','integer','bigint','decimal','numeric'
		  );
	" 2>>"$Logfile") || {
		ERRORmsg "Failed to discover phone columns"
		return 1
	}

	if [ -z "${phone_cols}" ]; then
		log "No phone-number columns found."
	else
		while IFS=$'\t' read -r schema table column max_length data_type; do
			[ -z "${schema}" ] && continue

			log "Hashing normalized phone value in ${schema}.${table}.${column}"

			case "${data_type}" in
				varchar|char|text|tinytext|mediumtext|longtext)
					if ! SANITIZE_TEXT_COLUMN_IN_BATCHES \
						"${schema}" "${table}" "${column}" "${max_length}" "phone"; then
						fail=1
					fi
					;;
				*)
					log "Replacing nonblank numeric phones in ${schema}.${table}.${column} with ${NUMERIC_PHONE_SANI_VALUE}"
					if ! run_mysql "
						SET SESSION sql_log_bin=0;
						SET SESSION lock_wait_timeout=3600;
						SET SESSION innodb_lock_wait_timeout=3600;
						UPDATE \`${schema}\`.\`${table}\`
						SET \`${column}\`=${NUMERIC_PHONE_SANI_VALUE}
						WHERE \`${column}\` IS NOT NULL;
					"; then
						ERRORmsg "FAILED numeric phone update: ${schema}.${table}.${column}"
						fail=1
					fi
					;;
			esac
		done <<< "${phone_cols}"
	fi

	if [ "${fail}" -ne 0 ]; then
		ERRORmsg "One or more personal-data columns failed to sanitize"
		return 1
	fi

	log "Sanitizing personal data DONE"
	return 0
}

SANITIZE_PASSWORDS() {
	log "Sanitizing password columns with the configured fixed value..."

	if [ -z "${PASSWORD_SANI_VALUE}" ]; then
		ERRORmsg "PASSWORD_SANI_VALUE must not be empty"
		return 1
	fi

	local cols
	local schema
	local table
	local column
	local max_length
	local password_length="${#PASSWORD_SANI_VALUE}"
	local password_hex
	local fail=0

	password_hex=$(printf '%s' "${PASSWORD_SANI_VALUE}" | od -An -tx1 | tr -d '[:space:]')
	if [ -z "${password_hex}" ]; then
		ERRORmsg "Could not encode PASSWORD_SANI_VALUE"
		return 1
	fi

	cols=$(mysql -h"${HOST}" -u"${MYSQL_ROOT_USER}" -p"${MYSQL_ROOT_PASS}" -N -B -e "
		SELECT
			c.TABLE_SCHEMA,
			c.TABLE_NAME,
			c.COLUMN_NAME,
			COALESCE(c.CHARACTER_MAXIMUM_LENGTH, 0)
		FROM information_schema.COLUMNS c
		JOIN information_schema.TABLES t
		  ON t.TABLE_SCHEMA = c.TABLE_SCHEMA
		 AND t.TABLE_NAME = c.TABLE_NAME
		WHERE c.TABLE_SCHEMA IN (${PASSWORD_SANI_SCHEMAS})
		  AND t.TABLE_TYPE = 'BASE TABLE'
		  AND c.DATA_TYPE IN ('varchar','char','text','tinytext','mediumtext','longtext')
		  AND (
			LOWER(c.COLUMN_NAME) REGEXP '(^|_)(password|passwd|pwd|passphrase)(_hash|_value|_encrypted|_digest)?$'
			OR LOWER(c.COLUMN_NAME) IN (
				'userpassword','loginpassword','dbpassword','ftppassword',
				'passwordhash','passwordvalue','newpassword','oldpassword'
			)
		  )
		ORDER BY c.TABLE_SCHEMA, c.TABLE_NAME, c.ORDINAL_POSITION;
	" 2>>"$Logfile") || {
		ERRORmsg "Failed to discover password columns"
		return 1
	}

	if [ -z "${cols}" ]; then
		log "No password-style text columns found."
		return 0
	fi

	while IFS=$'\t' read -r schema table column max_length; do
		[ -z "${schema}" ] && continue

		if [ "${max_length}" -lt "${password_length}" ]; then
			ERRORmsg "PASSWORD_SANI_VALUE has ${password_length} characters but ${schema}.${table}.${column} accepts only ${max_length}. Choose a shorter value."
			fail=1
			continue
		fi

		log "Replacing nonblank passwords in ${schema}.${table}.${column}"
		if ! mysql -h"${HOST}" -u"${MYSQL_ROOT_USER}" -p"${MYSQL_ROOT_PASS}" -e "
			SET SESSION sql_log_bin=0;
			SET SESSION lock_wait_timeout=3600;
			SET SESSION innodb_lock_wait_timeout=3600;

			UPDATE \`${schema}\`.\`${table}\`
			SET \`${column}\` = CONVERT(UNHEX('${password_hex}') USING utf8mb4)
			WHERE \`${column}\` IS NOT NULL
			  AND TRIM(\`${column}\`) != '';
		" >> "$Logfile" 2>&1; then
			ERRORmsg "FAILED password update: ${schema}.${table}.${column}"
			fail=1
		fi
	done <<< "${cols}"

	if [ "${fail}" -ne 0 ]; then
		ERRORmsg "One or more password columns failed to sanitize"
		return 1
	fi

	log "Sanitizing password columns DONE"
	return 0
}

UPDATE_FD_LMS_EXTRA_SERVICES() {
	log "Updating fd_lms.fd_lms_extra_services credentials..."

	if ! run_mysql "
		UPDATE fd_lms.fd_lms_extra_services
		SET credentials='${FD_LMS_EXTRA_SERVICES_CREDENTIALS}';
	"; then
		ERRORmsg "Failed to update fd_lms.fd_lms_extra_services credentials"
		return 1
	fi

	log "Updating fd_lms.fd_lms_extra_services credentials DONE"
	return 0
}

UPDATE_FD_COMPANY_REPORT_FTP() {
	log "Updating fd_lms.fd_company_report_ftp host and password..."

	if ! run_mysql "
		UPDATE fd_lms.fd_company_report_ftp
		SET ftp_host='${FD_COMPANY_REPORT_FTP_HOST}',
			ftp_password='${SANITIZED_PASSWORD}';
	"; then
		ERRORmsg "Failed to update fd_lms.fd_company_report_ftp"
		return 1
	fi

	log "Updating fd_lms.fd_company_report_ftp host and password DONE"
	return 0
}

SANITIZE_KEYCLOAK() {
	log "Sanitizing Keycloak..."

	run_mysql "UPDATE keycloak.CREDENTIAL SET VALUE='l7lk467owfLnuiQnoWTVIsbgFRe9GrMkTcvKmxV6ZP9G0shA/kE/6ES68QlQqX6P57MGLRvdYlg6kuikvmHOaQ==', SALT=X'314479510D0A78F59EE515937FFD1075' WHERE USER_ID='2910a4d7-a41b-44c5-b2fe-aac42ae6d609';"
	run_mysql "UPDATE keycloak.CREDENTIAL SET VALUE='PhI4J7JXnGBwfekJbuCCiJm8rAGjZdleaGizv7kLJUDQxyzQAQ2r4ap+a5a9gLf9IljFWa+cChZzVPxTVy9/PQ==', SALT=X'23EFBD6D9FD195316319AE956CA59894' WHERE USER_ID='450c572c-ef20-461d-bc32-0eb94db27ca1';"
	run_mysql "UPDATE keycloak.COMPONENT_CONFIG SET VALUE='${SANITIZED_PASSWORD}' WHERE NAME='bindCredential';"
	run_mysql "UPDATE keycloak.REALM_ATTRIBUTE SET VALUE=CONCAT('FleetDefense - Sanitized Data - ', CURDATE()) WHERE NAME='displayName';"
	run_mysql "UPDATE keycloak.CLIENT SET SECRET='11111111-1111-1111-1111-111111111111' WHERE REALM_ID='fleetdefense';"
	run_mysql "UPDATE fd_lms.config_plugins SET value='11111111-1111-1111-1111-111111111111' WHERE plugin='auth_oidc' AND name='clientsecret';"

	run_mysql "UPDATE fd_lms.fd_media_ftp SET ftp_host='media.fleetdefense.com', ftp_host_ip='10.102.70.148', ftp_password='cdnuser', ftp_user='cdnuser' WHERE id=2;"

	run_mysql "UPDATE fd_lms.adp_credentials SET url='https://fd.fleetdefense.com/test/adp/gomotive/driver_performance_events.php', api_key='cfXTppJM25' WHERE id=1;"
	run_mysql "UPDATE fd_lms.adp_credentials SET url='https://fd.fleetdefense.com/test/adp/gomotive/speeding_events.php', api_key='cfXTppJM25' WHERE id=3;"
	run_mysql "UPDATE fd_lms.adp_credentials SET url='https://fd.fleetdefense.com/test/adp/mock.php', api_key='cfXTppJM25' WHERE id=2;"
	run_mysql "UPDATE fd_lms.adp_credentials SET url='https://fd.fleetdefense.com/test/adp/mock.php', api_key='cfXTppJM25' WHERE id>3;"

	log "Sanitizing Keycloak DONE"
	return 0
}

SANITIZE_REPORTS() {
	log "Sanitizing reports..."

	run_mysql "UPDATE fd_lms.config_plugins SET value='powerbi@fleetdefense.com' WHERE plugin='local_report_pbi' AND name='pbiuser';"
	run_mysql "UPDATE fd_lms.config_plugins SET value='HaiDavid2' WHERE plugin='local_report_pbi' AND name='pbiuserkey';"
	run_mysql "UPDATE fd_lms.config_plugins SET value='091136f7-4511-419b-b11c-e71a3317589f' WHERE plugin='local_report_pbi' AND name='pbigroupid';"
	run_mysql "UPDATE fd_lms.config_plugins SET value='c8b826fe-c659-413b-b0c9-44ab1772d370' WHERE plugin='local_report_pbi' AND name='pbidatasetid';"
	run_mysql "UPDATE fd_lms.config_plugins SET value='4621d62b-bcc9-4753-88e0-c52a06f282d6' WHERE plugin='local_report_pbi' AND name='pbireportid';"

	log "Sanitizing reports DONE"
	return 0
}

SANITIZE_AD_VAULT_TABLES() {
	log "Truncating ad_vault tables..."

	for table in agents migrations oauth_access_tokens oauth_auth_codes oauth_clients oauth_personal_access_clients oauth_refresh_tokens personal_access_tokens users; do
		run_mysql "TRUNCATE TABLE ad_vault.${table};" || true
	done

	log "Truncating ad_vault tables DONE"
	return 0
}

WIPE_OUT_MYSQL_FD_LMS_SESSIONS() {
	log "Truncating fd_lms.sessions..."
	run_mysql "TRUNCATE TABLE fd_lms.sessions;" || true
	return 0
}

CREATE_EMAIL_HASH_FUNCTION() {
	local validation

	log "Installing temporary ${EMAIL_SANI_HASH_LENGTH}-character Base37 email hash function..."
	if ! mysql -h"${HOST}" -u"${MYSQL_ROOT_USER}" -p"${MYSQL_ROOT_PASS}" >> "$Logfile" 2>&1 <<MYSQL
SET SESSION sql_log_bin=0;
DROP FUNCTION IF EXISTS ${EMAIL_HASH_FUNCTION_SCHEMA}.${EMAIL_HASH_FUNCTION_NAME};
DELIMITER //
CREATE FUNCTION ${EMAIL_HASH_FUNCTION_SCHEMA}.${EMAIL_HASH_FUNCTION_NAME}(
	raw_email LONGTEXT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci
)
RETURNS CHAR(16) CHARACTER SET ascii
DETERMINISTIC
CONTAINS SQL
SQL SECURITY INVOKER
BEGIN
	DECLARE digest_hex CHAR(64) CHARACTER SET ascii;
	DECLARE remainder_value DECIMAL(65,0) DEFAULT 0;
	DECLARE chunk_value DECIMAL(65,0);
	DECLARE digit_value INT UNSIGNED;
	DECLARE result_value VARCHAR(16) CHARACTER SET ascii DEFAULT '';
	DECLARE chunk_number INT UNSIGNED DEFAULT 0;
	DECLARE digit_number INT UNSIGNED DEFAULT 0;

	IF raw_email IS NULL THEN
		RETURN NULL;
	END IF;
	SET raw_email = TRIM(raw_email);
	IF raw_email = '' THEN
		RETURN '';
	END IF;

	SET digest_hex = SHA2(CONCAT('${EMAIL_SANI_SALT}', LOWER(raw_email)), 256);

	-- CONV is limited to 64 bits. Fold the four SHA-256 words into a
	-- DECIMAL remainder modulo 37^16 so the result exactly matches repeated
	-- divmod(..., 37) of the full, big-endian SHA-256 integer.
	WHILE chunk_number < 4 DO
		SET chunk_value = CAST(
			CONV(SUBSTRING(digest_hex, chunk_number * 16 + 1, 16), 16, 10)
			AS DECIMAL(65,0)
		);
		SET remainder_value = MOD(
			remainder_value * 18446744073709551616 + chunk_value,
			${EMAIL_SANI_HASH_MODULUS}
		);
		SET chunk_number = chunk_number + 1;
	END WHILE;

	WHILE digit_number < ${EMAIL_SANI_HASH_LENGTH} DO
		SET digit_value = MOD(remainder_value, 37);
		SET result_value = CONCAT(
			result_value,
			SUBSTRING('abcdefghijklmnopqrstuvwxyz0123456789_', digit_value + 1, 1)
		);
		SET remainder_value = FLOOR(remainder_value / 37);
		SET digit_number = digit_number + 1;
	END WHILE;

	RETURN result_value;
END//
DELIMITER ;
MYSQL
	then
		ERRORmsg "Could not install the temporary Base37 email hash function"
		return 1
	fi
	EMAIL_HASH_FUNCTION_INSTALLED=1

	validation=$(mysql -h"${HOST}" -u"${MYSQL_ROOT_USER}" -p"${MYSQL_ROOT_PASS}" -N -B -e "
		SELECT CASE
			WHEN ${EMAIL_HASH_FUNCTION_SCHEMA}.${EMAIL_HASH_FUNCTION_NAME}(' User.Name+tag@Example.COM ') =
			     ${EMAIL_HASH_FUNCTION_SCHEMA}.${EMAIL_HASH_FUNCTION_NAME}('user.name+tag@example.com')
			 AND CHAR_LENGTH(${EMAIL_HASH_FUNCTION_SCHEMA}.${EMAIL_HASH_FUNCTION_NAME}('user.name+tag@example.com')) = ${EMAIL_SANI_HASH_LENGTH}
			 AND ${EMAIL_HASH_FUNCTION_SCHEMA}.${EMAIL_HASH_FUNCTION_NAME}('user.name+tag@example.com') NOT REGEXP '[^a-z0-9_]'
			 AND CHAR_LENGTH(
				${EMAIL_HASH_FUNCTION_SCHEMA}.${EMAIL_HASH_FUNCTION_NAME}(
					CONVERT(UNHEX('75736572EFBCA0706D692E636F6D') USING utf8mb4)
				)
			 ) = ${EMAIL_SANI_HASH_LENGTH}
			THEN 'OK'
			ELSE 'FAILED'
		END;
	" 2>>"$Logfile") || {
		ERRORmsg "Could not validate the temporary Base37 email hash function"
		return 1
	}
	if [ "${validation}" != "OK" ]; then
		ERRORmsg "Temporary Base37 email hash function failed normalization, Unicode, or output validation"
		return 1
	fi

	log "Temporary Base37 email hash function installed and validated."
	return 0
}

DROP_EMAIL_HASH_FUNCTION() {
	if [ "${EMAIL_HASH_FUNCTION_INSTALLED}" -eq 0 ]; then
		return 0
	fi

	log "Removing temporary Base37 email hash function..."
	if ! run_mysql "SET SESSION sql_log_bin=0; DROP FUNCTION IF EXISTS ${EMAIL_HASH_FUNCTION_SCHEMA}.${EMAIL_HASH_FUNCTION_NAME};"; then
		return 1
	fi
	EMAIL_HASH_FUNCTION_INSTALLED=0
	log "Temporary Base37 email hash function removed."
	return 0
}

DROP_APERTURE_EMAIL_SECONDARY_INDEXES() {
	local existing drop_clauses="" index

	if [ "${OPTIMIZE_APERTURE_EMAIL_INDEXES}" != "1" ]; then
		return 0
	fi

	existing=$(mysql -h"${HOST}" -u"${MYSQL_ROOT_USER}" -p"${MYSQL_ROOT_PASS}" -N -B -e "
		SELECT DISTINCT INDEX_NAME
		FROM information_schema.STATISTICS
		WHERE TABLE_SCHEMA='fd_lms'
		  AND TABLE_NAME='aperture_email_log'
		  AND INDEX_NAME IN (
			'aperemailog_ema_uix',
			'aperemailog_ema_uix_uix',
			'aperemailog_ematyp_ix'
		  )
		ORDER BY INDEX_NAME;
	" 2>>"$Logfile") || {
		ERRORmsg "Could not inspect aperture secondary indexes before removal"
		return 1
	}

	log "Aperture secondary indexes before removal: ${existing//$'\n'/, }"
	for index in aperemailog_ema_uix aperemailog_ema_uix_uix aperemailog_ematyp_ix; do
		if printf '%s\n' "${existing}" | grep -Fxq "${index}"; then
			[ -n "${drop_clauses}" ] && drop_clauses+=", "
			drop_clauses+="DROP INDEX \`${index}\`"
		fi
	done

	APERTURE_INDEXES_TEMPORARILY_REMOVED=1
	if [ -z "${drop_clauses}" ]; then
		log "Aperture email secondary indexes are already absent."
		return 0
	fi

	log "Temporarily dropping aperture email secondary indexes for faster updates..."
	if ! run_mysql "ALTER TABLE fd_lms.aperture_email_log ${drop_clauses}, ALGORITHM=INPLACE, LOCK=NONE;"; then
		ERRORmsg "Failed to remove aperture secondary indexes"
		return 1
	fi
	log "Aperture secondary index removal completed."
	return 0
}

RESTORE_APERTURE_EMAIL_SECONDARY_INDEXES() {
	local existing add_clauses="" index final_count

	if [ "${OPTIMIZE_APERTURE_EMAIL_INDEXES}" != "1" ]; then
		return 0
	fi

	existing=$(mysql -h"${HOST}" -u"${MYSQL_ROOT_USER}" -p"${MYSQL_ROOT_PASS}" -N -B -e "
		SELECT DISTINCT INDEX_NAME
		FROM information_schema.STATISTICS
		WHERE TABLE_SCHEMA='fd_lms'
		  AND TABLE_NAME='aperture_email_log'
		  AND INDEX_NAME IN (
			'aperemailog_ema_uix',
			'aperemailog_ema_uix_uix',
			'aperemailog_ematyp_ix'
		  )
		ORDER BY INDEX_NAME;
	" 2>>"$Logfile") || {
		ERRORmsg "Could not inspect aperture secondary indexes before repair"
		return 1
	}

	log "Aperture secondary indexes before repair: ${existing//$'\n'/, }"
	for index in aperemailog_ema_uix aperemailog_ema_uix_uix aperemailog_ematyp_ix; do
		if ! printf '%s\n' "${existing}" | grep -Fxq "${index}"; then
			[ -n "${add_clauses}" ] && add_clauses+=", "
			case "${index}" in
				aperemailog_ema_uix) add_clauses+="ADD KEY aperemailog_ema_uix (email)" ;;
				aperemailog_ema_uix_uix) add_clauses+="ADD KEY aperemailog_ema_uix_uix (licenseid, email)" ;;
				aperemailog_ematyp_ix) add_clauses+="ADD KEY aperemailog_ematyp_ix (email, type)" ;;
			esac
		fi
	done

	if [ -z "${add_clauses}" ]; then
		log "Aperture email secondary indexes are already present."
		APERTURE_INDEXES_TEMPORARILY_REMOVED=0
		return 0
	fi

	log "Adding missing aperture secondary indexes in one operation..."
	if ! run_mysql "ALTER TABLE fd_lms.aperture_email_log ${add_clauses}, ALGORITHM=INPLACE, LOCK=NONE;"; then
		ERRORmsg "Failed to add missing aperture secondary indexes"
		return 1
	fi

	final_count=$(mysql -h"${HOST}" -u"${MYSQL_ROOT_USER}" -p"${MYSQL_ROOT_PASS}" -N -B -e "
		SELECT COUNT(DISTINCT INDEX_NAME)
		FROM information_schema.STATISTICS
		WHERE TABLE_SCHEMA='fd_lms' AND TABLE_NAME='aperture_email_log'
		  AND INDEX_NAME IN ('aperemailog_ema_uix','aperemailog_ema_uix_uix','aperemailog_ematyp_ix');
	" 2>>"$Logfile") || return 1
	if [ "${final_count}" != "3" ]; then
		ERRORmsg "Aperture index verification failed: ${final_count} of 3 indexes exist"
		return 1
	fi
	APERTURE_INDEXES_TEMPORARILY_REMOVED=0
	log "All three aperture secondary indexes verified."
	return 0
}

IS_FAST_BATCH_EMAIL_TABLE() {
	local target="$1"
	local configured

	for configured in "${EMAIL_FAST_BATCH_TABLES[@]}"; do
		if [ "${configured}" = "${target}" ]; then
			return 0
		fi
	done

	return 1
}

SANITIZE_EMAIL_COLUMN_IN_KEY_RANGES() {
	local schema="$1"
	local table="$2"
	local column="$3"
	local batch_key
	local batch_size="${EMAIL_SANI_ROW_BATCH_SIZE}"
	local next_key=""
	local lower_sql=""
	local upper_sql=""
	local boundary
	local output
	local affected
	local total=0
	local mysql_status
	local is_final_batch
	local retry_count=0
	local batch_started batch_elapsed range_description

	batch_key=$(mysql -h"${HOST}" -u"${MYSQL_ROOT_USER}" -p"${MYSQL_ROOT_PASS}" -N -B -e "
		SELECT s.COLUMN_NAME
		FROM information_schema.STATISTICS s
		JOIN information_schema.COLUMNS c
		  ON c.TABLE_SCHEMA = s.TABLE_SCHEMA
		 AND c.TABLE_NAME = s.TABLE_NAME
		 AND c.COLUMN_NAME = s.COLUMN_NAME
		WHERE s.TABLE_SCHEMA = '${schema}'
		  AND s.TABLE_NAME = '${table}'
		  AND s.NON_UNIQUE = 0
		  AND s.SEQ_IN_INDEX = 1
		  AND c.IS_NULLABLE = 'NO'
		  AND c.DATA_TYPE IN ('tinyint','smallint','mediumint','int','integer','bigint')
		  AND NOT EXISTS (
			SELECT 1
			FROM information_schema.STATISTICS s2
			WHERE s2.TABLE_SCHEMA = s.TABLE_SCHEMA
			  AND s2.TABLE_NAME = s.TABLE_NAME
			  AND s2.INDEX_NAME = s.INDEX_NAME
			  AND s2.SEQ_IN_INDEX > 1
		  )
		ORDER BY (s.INDEX_NAME = 'PRIMARY') DESC,
		         COALESCE(s.CARDINALITY, 0) DESC
		LIMIT 1;
	" 2>>"$Logfile") || return 1

	if [ -z "${batch_key}" ]; then
		log "No single numeric primary/unique key found for ${schema}.${table}; using the original email update."
		return 2
	fi

	if [[ ! "${batch_key}" =~ ^[A-Za-z0-9_-]+$ ]]; then
		ERRORmsg "Unsafe batch-key name returned for ${schema}.${table}: ${batch_key}"
		return 1
	fi

	log "Fast email sanitization for ${schema}.${table}.${column} using key ${batch_key} and batches of ${batch_size} rows."

	# Start at the first value that is not already in this script's sanitized
	# format. This makes an interrupted run safe to resume without double-hashing
	# the rows that committed successfully before the interruption.
	next_key=$(mysql -h"${HOST}" -u"${MYSQL_ROOT_USER}" -p"${MYSQL_ROOT_PASS}" -N -B -e "
		SELECT \`${batch_key}\`
		FROM \`${schema}\`.\`${table}\`
		WHERE \`${column}\` IS NOT NULL
		  AND \`${column}\` != ''
		  AND \`${column}\` LIKE '%@%'
		  AND NOT (
			CHAR_LENGTH(\`${column}\`) = ${EMAIL_SANI_HASH_LENGTH} + CHAR_LENGTH('@${EMAIL_SANI_DOMAIN}')
			AND RIGHT(\`${column}\`, CHAR_LENGTH('@${EMAIL_SANI_DOMAIN}')) = '@${EMAIL_SANI_DOMAIN}'
			AND LEFT(\`${column}\`, ${EMAIL_SANI_HASH_LENGTH}) NOT REGEXP '[^a-z0-9_]'
		  )
		ORDER BY \`${batch_key}\`
		LIMIT 1;
	" 2>>"$Logfile") || {
		ERRORmsg "Could not locate the first unfinished email row for ${schema}.${table}.${column}"
		return 1
	}

	if [ -z "${next_key}" ]; then
		log "No unfinished email rows remain in ${schema}.${table}.${column}."
		return 0
	fi

	if [[ ! "${next_key}" =~ ^-?[0-9]+$ ]]; then
		ERRORmsg "Invalid first unfinished key for ${schema}.${table}.${column}: ${next_key}"
		return 1
	fi

	log "Starting or resuming ${schema}.${table}.${column} at ${batch_key}=${next_key}."

	while true; do
		if [ -n "${next_key}" ]; then
			lower_sql="AND \`${batch_key}\` >= ${next_key}"
		else
			lower_sql=""
		fi

		boundary=$(mysql -h"${HOST}" -u"${MYSQL_ROOT_USER}" -p"${MYSQL_ROOT_PASS}" -N -B -e "
			SELECT \`${batch_key}\`
			FROM \`${schema}\`.\`${table}\`
			WHERE \`${column}\` IS NOT NULL
			  AND \`${column}\` != ''
			  AND \`${column}\` LIKE '%@%'
			  AND NOT (
				CHAR_LENGTH(\`${column}\`) = ${EMAIL_SANI_HASH_LENGTH} + CHAR_LENGTH('@${EMAIL_SANI_DOMAIN}')
				AND RIGHT(\`${column}\`, CHAR_LENGTH('@${EMAIL_SANI_DOMAIN}')) = '@${EMAIL_SANI_DOMAIN}'
				AND LEFT(\`${column}\`, ${EMAIL_SANI_HASH_LENGTH}) NOT REGEXP '[^a-z0-9_]'
			  )
			  ${lower_sql}
			ORDER BY \`${batch_key}\`
			LIMIT ${batch_size}, 1;
		" 2>>"$Logfile") || {
			ERRORmsg "Could not determine the next email batch for ${schema}.${table}.${column}"
			return 1
		}

		if [ -n "${boundary}" ]; then
			if [[ ! "${boundary}" =~ ^-?[0-9]+$ ]]; then
				ERRORmsg "Invalid email batch boundary for ${schema}.${table}.${column}: ${boundary}"
				return 1
			fi
			upper_sql="AND \`${batch_key}\` < ${boundary}"
			is_final_batch=0
		else
			upper_sql=""
			is_final_batch=1
		fi

		if [ -n "${boundary}" ]; then
			range_description="${batch_key} >= ${next_key} and ${batch_key} < ${boundary}"
		else
			range_description="${batch_key} >= ${next_key} through final unfinished row"
		fi
		batch_started=$(date +%s)
		log "Starting email batch for ${schema}.${table}.${column}: ${range_description}; batch size=${batch_size}; retry=${retry_count}."

		output=$(mysql -h"${HOST}" -u"${MYSQL_ROOT_USER}" -p"${MYSQL_ROOT_PASS}" -N -B -e "
			SET SESSION sql_log_bin=0;
			SET SESSION lock_wait_timeout=3600;
			SET SESSION innodb_lock_wait_timeout=3600;
			SELECT CONCAT('connection_id=', CONNECTION_ID());

			UPDATE \`${schema}\`.\`${table}\`
			SET \`${column}\` = CONCAT(
				${EMAIL_HASH_FUNCTION_SCHEMA}.${EMAIL_HASH_FUNCTION_NAME}(\`${column}\`),
				'@${EMAIL_SANI_DOMAIN}'
			)
			WHERE \`${column}\` IS NOT NULL
			  AND \`${column}\` != ''
			  AND \`${column}\` LIKE '%@%'
			  AND NOT (
				CHAR_LENGTH(\`${column}\`) = ${EMAIL_SANI_HASH_LENGTH} + CHAR_LENGTH('@${EMAIL_SANI_DOMAIN}')
				AND RIGHT(\`${column}\`, CHAR_LENGTH('@${EMAIL_SANI_DOMAIN}')) = '@${EMAIL_SANI_DOMAIN}'
				AND LEFT(\`${column}\`, ${EMAIL_SANI_HASH_LENGTH}) NOT REGEXP '[^a-z0-9_]'
			  )
			  ${lower_sql}
			  ${upper_sql};

			SELECT ROW_COUNT();
		" 2>&1)
		mysql_status=$?
		printf '%s\n' "${output}" >> "$Logfile"

		if [ "${mysql_status}" -ne 0 ]; then
			batch_elapsed=$(($(date +%s) - batch_started))
			ERRORmsg "Email batch exited with status ${mysql_status} after ${batch_elapsed}s: ${schema}.${table}.${column}; ${range_description}"
			if { [[ "${output}" == *"Terminal close -- query aborted"* ]] ||
			     [[ "${output}" == *"ERROR 1205"* ]] ||
			     [[ "${output}" == *"ERROR 1213"* ]]; } &&
			   [ "${retry_count}" -lt "${EMAIL_SANI_BATCH_RETRIES}" ]; then
				retry_count=$((retry_count + 1))
				log "Transient email batch interruption; retry ${retry_count}/${EMAIL_SANI_BATCH_RETRIES} for ${schema}.${table}.${column}."
				sleep 5
				continue
			fi

			if [[ "${output}" == *"ERROR 1206"* ]] && [ "${batch_size}" -gt "${EMAIL_SANI_MIN_ROW_BATCH_SIZE}" ]; then
				batch_size=$((batch_size / 2))
				if [ "${batch_size}" -lt "${EMAIL_SANI_MIN_ROW_BATCH_SIZE}" ]; then
					batch_size="${EMAIL_SANI_MIN_ROW_BATCH_SIZE}"
				fi
				log "Email lock limit reached for ${schema}.${table}.${column}; retrying with ${batch_size} rows per batch."
				continue
			fi

			ERRORmsg "FAILED batched email update: ${schema}.${table}.${column}; MySQL output: ${output//$'\n'/ | }"
			CAPTURE_MYSQL_DIAGNOSTICS
			return 1
		fi
		retry_count=0

		affected=$(printf '%s\n' "${output}" | awk '/^[0-9]+$/ { value=$0 } END { print value }')
		if [[ ! "${affected}" =~ ^[0-9]+$ ]]; then
			ERRORmsg "Could not read affected-row count for ${schema}.${table}.${column}"
			return 1
		fi

		total=$((total + affected))
		batch_elapsed=$(($(date +%s) - batch_started))
		log "Sanitized ${total} email rows in ${schema}.${table}.${column} (latest batch: ${affected}; batch time: ${batch_elapsed}s)."

		if [ "${is_final_batch}" -eq 1 ]; then
			break
		fi

		next_key="${boundary}"
	done

	return 0
}

SANITIZE_EMAILS() {
	log "Sanitizing email columns across BASE TABLES only..."

	local cols
	cols=$(mysql -h"${HOST}" -u"${MYSQL_ROOT_USER}" -p"${MYSQL_ROOT_PASS}" -N -B -e "
		SELECT CONCAT(c.TABLE_SCHEMA,'.',c.TABLE_NAME,'.',c.COLUMN_NAME)
		FROM information_schema.COLUMNS c
		JOIN information_schema.TABLES t
		  ON t.TABLE_SCHEMA = c.TABLE_SCHEMA
		 AND t.TABLE_NAME = c.TABLE_NAME
		WHERE c.TABLE_SCHEMA IN (${EMAIL_SANI_SCHEMAS})
		  AND t.TABLE_TYPE = 'BASE TABLE'
		  AND c.COLUMN_NAME LIKE '%email%'
		  AND c.COLUMN_NAME NOT IN ('newemail')
		  AND c.DATA_TYPE IN ('varchar','char','text','tinytext','mediumtext','longtext');
	" 2>>"$Logfile")

	if [ -z "$cols" ]; then
		log "No email columns found."
		return 0
	fi

	echo "$cols" | tee -a "$Logfile"

	_update_one_email_col() {
		local schema="$1"
		local table="$2"
		local column="$3"
		local output status

		log "Updating ${schema}.${table}.${column}"

		output=$(mysql -h"${HOST}" -u"${MYSQL_ROOT_USER}" -p"${MYSQL_ROOT_PASS}" -e "
			SET SESSION lock_wait_timeout=3600;
			SET SESSION innodb_lock_wait_timeout=3600;

			UPDATE \`${schema}\`.\`${table}\`
			SET \`${column}\` = CONCAT(
				${EMAIL_HASH_FUNCTION_SCHEMA}.${EMAIL_HASH_FUNCTION_NAME}(\`${column}\`),
				'@${EMAIL_SANI_DOMAIN}'
			)
			WHERE \`${column}\` IS NOT NULL
			  AND \`${column}\` != ''
			  AND \`${column}\` LIKE '%@%'
			  AND NOT (
				CHAR_LENGTH(\`${column}\`) = ${EMAIL_SANI_HASH_LENGTH} + CHAR_LENGTH('@${EMAIL_SANI_DOMAIN}')
				AND RIGHT(\`${column}\`, CHAR_LENGTH('@${EMAIL_SANI_DOMAIN}')) = '@${EMAIL_SANI_DOMAIN}'
				AND LEFT(\`${column}\`, ${EMAIL_SANI_HASH_LENGTH}) NOT REGEXP '[^a-z0-9_]'
			  );
		" 2>&1)
		status=$?
		printf '%s\n' "${output}" >> "$Logfile"
		if [ "${status}" -ne 0 ]; then
			ERRORmsg "FAILED email update: ${schema}.${table}.${column}; MySQL output: ${output//$'\n'/ | }"
		fi

		return "${status}"
	}

	local fail=0
	local batch_status
	local column_status
	local indexes_dropped

	while IFS='.' read -r schema table column; do
		[ -z "$schema" ] && continue

		if IS_FAST_BATCH_EMAIL_TABLE "${schema}.${table}"; then
			column_status=0
			indexes_dropped=0

			if [ "${schema}.${table}.${column}" = "fd_lms.aperture_email_log.email" ] && \
			   [ "${OPTIMIZE_APERTURE_EMAIL_INDEXES}" = "1" ]; then
				if DROP_APERTURE_EMAIL_SECONDARY_INDEXES; then
					indexes_dropped=1
				else
					log "FAILED to prepare aperture email indexes for sanitization"
					fail=1
					continue
				fi
			fi

			SANITIZE_EMAIL_COLUMN_IN_KEY_RANGES "$schema" "$table" "$column"
			batch_status=$?

			if [ "${batch_status}" -eq 2 ]; then
				if ! _update_one_email_col "$schema" "$table" "$column"; then
					column_status=1
				fi
			elif [ "${batch_status}" -ne 0 ]; then
				column_status=1
			fi

			if [ "${indexes_dropped}" -eq 1 ]; then
				if ! RESTORE_APERTURE_EMAIL_SECONDARY_INDEXES; then
					column_status=1
				fi
			fi

			if [ "${column_status}" -ne 0 ]; then
				log "FAILED email update: ${schema}.${table}.${column}"
				fail=1
			fi
		elif ! _update_one_email_col "$schema" "$table" "$column"; then
			log "FAILED email update: ${schema}.${table}.${column}"
			fail=1
		fi
	done <<< "$cols"

	if [ "$fail" -ne 0 ]; then
		ERRORmsg "One or more email columns failed to sanitize"
		return 1
	fi

	log "Sanitizing email columns DONE"
	return 0
}

RESUME_APERTURE_EMAIL() {
	local status=0
	local indexes_dropped=0
	local legacy_hash_count

	log "Resume mode: finishing fd_lms.aperture_email_log.email only..."
	legacy_hash_count=$(mysql -h"${HOST}" -u"${MYSQL_ROOT_USER}" -p"${MYSQL_ROOT_PASS}" -N -B -e "
		SELECT COUNT(*)
		FROM fd_lms.aperture_email_log
		WHERE email IS NOT NULL
		  AND CHAR_LENGTH(email) = 64 + CHAR_LENGTH('@${EMAIL_SANI_DOMAIN}')
		  AND RIGHT(email, CHAR_LENGTH('@${EMAIL_SANI_DOMAIN}')) = '@${EMAIL_SANI_DOMAIN}'
		  AND LEFT(email, 64) NOT REGEXP '[^0-9a-f]';
	" 2>>"$Logfile") || {
		ERRORmsg "Could not check for legacy 64-character email hashes before resume"
		return 1
	}
	if [[ ! "${legacy_hash_count}" =~ ^[0-9]+$ ]]; then
		ERRORmsg "Invalid legacy email hash count returned before resume: ${legacy_hash_count}"
		return 1
	fi
	if [ "${legacy_hash_count}" -ne 0 ]; then
		ERRORmsg "Found ${legacy_hash_count} legacy 64-character email hashes. A mixed-format resume cannot preserve the same pseudonym for duplicate original emails; restore the original backup and use RUN_MODE=full."
		return 1
	fi

	if DROP_APERTURE_EMAIL_SECONDARY_INDEXES; then
		indexes_dropped=1
	else
		ERRORmsg "Could not prepare aperture email indexes for resume"
		return 1
	fi

	SANITIZE_EMAIL_COLUMN_IN_KEY_RANGES fd_lms aperture_email_log email || status=1

	if [ "${indexes_dropped}" -eq 1 ]; then
		RESTORE_APERTURE_EMAIL_SECONDARY_INDEXES || status=1
	fi

	if [ "${status}" -ne 0 ]; then
		ERRORmsg "Aperture email resume failed"
		return 1
	fi

	log "Aperture email resume DONE"
	return 0
}

CLEANUP_SANITIZE_DATA() {
	log "Final cleanup sanitize data..."

	run_mysql "UPDATE fd_lms.user SET alternatename = NULL;" || true
	run_mysql "ALTER TABLE fd_lms.user DROP COLUMN emailOld;" || true

	log "Final cleanup sanitize data DONE"
	return 0
}

DUMP_STRUCTURES() {
	log "Dumping structures..."

	mysqldump -h"${HOST}" -u"${MYSQL_ROOT_USER}" -p"${MYSQL_ROOT_PASS}" \
		--single-transaction \
		--skip-triggers \
		--no-data \
		--databases ${DATABASES} > "${STRUCTURES_SQL}" 2>>"$Logfile"

	if [ "$?" -ne 0 ]; then
		ERRORmsg "mysqldump structures failed"
		return 1
	fi

	log "Dumping triggers..."

	mysqldump -h"${HOST}" -u"${MYSQL_ROOT_USER}" -p"${MYSQL_ROOT_PASS}" \
		${DBOPTIONS} \
		--triggers \
		--no-create-info \
		--no-data \
		--no-create-db \
		--skip-opt \
		--databases ${DATABASES} > "${TRIGGERS_SQL}" 2>>"$Logfile"

	if [ "$?" -ne 0 ]; then
		ERRORmsg "mysqldump triggers failed"
		return 1
	fi

	cat > "${USERS_PERMS_SQL}" <<EOF
CREATE USER IF NOT EXISTS 'aperture'@'%' IDENTIFIED BY '${SANITIZED_PASSWORD}';
CREATE USER IF NOT EXISTS 'lms'@'%' IDENTIFIED BY '${SANITIZED_PASSWORD}';
GRANT ALL PRIVILEGES ON *.* TO 'aperture'@'%' IDENTIFIED BY '${SANITIZED_PASSWORD}';
GRANT ALL PRIVILEGES ON fd_lms.* TO 'lms'@'%' IDENTIFIED BY '${SANITIZED_PASSWORD}';
GRANT SELECT, EXECUTE ON AD_Main.* TO 'lms'@'%' IDENTIFIED BY '${SANITIZED_PASSWORD}';
FLUSH PRIVILEGES;
EOF

	log "Dumping structures/triggers/users DONE"
	return 0
}

SANITIZE_MYSQL_USERS() {
	log "Sanitizing MySQL users and permissions..."

	run_mysql "DELETE FROM mysql.db WHERE User NOT IN ('root','mysql.session','mysql.sys');"
	run_mysql "DELETE FROM mysql.user WHERE User NOT IN ('root','mysql.session','mysql.sys');"

	run_mysql "CREATE USER IF NOT EXISTS 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASS}';"
	run_mysql "ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASS}';"
	run_mysql "GRANT ALL PRIVILEGES ON *.* TO 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASS}' WITH GRANT OPTION;"

	run_mysql "CREATE USER IF NOT EXISTS 'root'@'127.0.0.1' IDENTIFIED BY '${MYSQL_ROOT_PASS}';"
	run_mysql "GRANT ALL PRIVILEGES ON *.* TO 'root'@'127.0.0.1' IDENTIFIED BY '${MYSQL_ROOT_PASS}' WITH GRANT OPTION;"

	run_mysql "CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASS}';"
	run_mysql "GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASS}' WITH GRANT OPTION;"

	for user in aperture dams dw keycloak lfa lms scorm ad_vault proxysql proxysql1 proxysql2 proxysql3 fd_inroads docker replica_user; do
		run_mysql "CREATE USER IF NOT EXISTS '${user}'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASS}';"
		run_mysql "GRANT ALL PRIVILEGES ON *.* TO '${user}'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASS}';"
	done

	run_mysql "CREATE USER IF NOT EXISTS 'nagios'@'10.%' IDENTIFIED BY '${SANITIZED_PASSWORD}';"
	run_mysql "GRANT SELECT ON *.* TO 'nagios'@'10.%';"

	run_mysql "CREATE USER IF NOT EXISTS 'zbx_monitor'@'%' IDENTIFIED BY '${SANITIZED_PASSWORD}';"
	run_mysql "GRANT USAGE, REPLICATION CLIENT, PROCESS, SHOW DATABASES, SHOW VIEW ON *.* TO 'zbx_monitor'@'%';"

	run_mysql "FLUSH PRIVILEGES;"

	log "Sanitizing MySQL users and permissions DONE"
	return 0
}

RECREATE_MONITOR_PROXYSQL_USERS() {
	local verified_count

	log "Checking required monitor and ProxySQL accounts before recreation..."
	if ! run_mysql "
		SELECT User, Host
		FROM mysql.user
		WHERE Host = '%'
		  AND User IN (
			'monitor',
			'monitor2',
			'monitor3',
			'monitorps1',
			'monitorps2',
			'monitorps3',
			'proxysql',
			'proxysql1',
			'proxysql2',
			'proxysql3'
		  )
		ORDER BY User;
	"; then
		ERRORmsg "Failed to check existing monitor and ProxySQL accounts"
		return 1
	fi

	log "Dropping and recreating the 10 required monitor and ProxySQL accounts..."
	if ! run_mysql "
		DROP USER IF EXISTS
			'monitor'@'%',
			'monitor2'@'%',
			'monitor3'@'%',
			'monitorps1'@'%',
			'monitorps2'@'%',
			'monitorps3'@'%',
			'proxysql'@'%',
			'proxysql1'@'%',
			'proxysql2'@'%',
			'proxysql3'@'%';

		CREATE USER
			'monitor'@'%'    IDENTIFIED BY '${MYSQL_ROOT_PASS}',
			'monitor2'@'%'   IDENTIFIED BY '${MYSQL_ROOT_PASS}',
			'monitor3'@'%'   IDENTIFIED BY '${MYSQL_ROOT_PASS}',
			'monitorps1'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASS}',
			'monitorps2'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASS}',
			'monitorps3'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASS}',
			'proxysql'@'%'   IDENTIFIED BY '${MYSQL_ROOT_PASS}',
			'proxysql1'@'%'  IDENTIFIED BY '${MYSQL_ROOT_PASS}',
			'proxysql2'@'%'  IDENTIFIED BY '${MYSQL_ROOT_PASS}',
			'proxysql3'@'%'  IDENTIFIED BY '${MYSQL_ROOT_PASS}';

		FLUSH PRIVILEGES;
	"; then
		ERRORmsg "Failed to recreate the required monitor and ProxySQL accounts"
		return 1
	fi

	log "Verifying required monitor and ProxySQL accounts after recreation..."
	if ! run_mysql "
		SELECT User, Host
		FROM mysql.user
		WHERE Host = '%'
		  AND User IN (
			'monitor',
			'monitor2',
			'monitor3',
			'monitorps1',
			'monitorps2',
			'monitorps3',
			'proxysql',
			'proxysql1',
			'proxysql2',
			'proxysql3'
		  )
		ORDER BY User;
	"; then
		ERRORmsg "Failed to list recreated monitor and ProxySQL accounts"
		return 1
	fi

	verified_count=$(mysql -h"${HOST}" -u"${MYSQL_ROOT_USER}" -p"${MYSQL_ROOT_PASS}" -N -B -e "
		SELECT COUNT(*)
		FROM mysql.user
		WHERE Host = '%'
		  AND User IN (
			'monitor', 'monitor2', 'monitor3',
			'monitorps1', 'monitorps2', 'monitorps3',
			'proxysql', 'proxysql1', 'proxysql2', 'proxysql3'
		  );
	" 2>>"${Logfile}") || {
		ERRORmsg "Failed to count recreated monitor and ProxySQL accounts"
		return 1
	}

	if [ "${verified_count}" != "10" ]; then
		ERRORmsg "Monitor/ProxySQL account verification failed: expected 10 accounts, found ${verified_count}"
		return 1
	fi

	log "Verified all 10 required monitor and ProxySQL accounts"
	return 0
}

ADD_REQUIRED_AD_VAULT_ROWS() {
	log "Adding required ad_vault users and agent..."

	if ! run_mysql "
		START TRANSACTION;

		INSERT INTO ad_vault.users
			(id, username, email, password, isadmin, created_at, updated_at, deleted_at)
		VALUES
			(1, 'VaultAdmin', 'advault.admin@alertdriving.com', '\$2y\$12\$62Qdq6nlHq200yvcm1PJ.u6n6rFH8neBoum4FOzj89WDwcQlih0UG', 1, NULL, NULL, NULL)
		ON DUPLICATE KEY UPDATE
			username=VALUES(username),
			email=VALUES(email),
			password=VALUES(password),
			isadmin=VALUES(isadmin),
			created_at=VALUES(created_at),
			updated_at=VALUES(updated_at),
			deleted_at=VALUES(deleted_at);

		INSERT INTO ad_vault.users
			(id, username, email, password, isadmin, created_at, updated_at, deleted_at)
		VALUES
			(4, 'VaultAgent1.user1', 'harshil.joshi@alertdriving.com', '\$2y\$12\$xagFCc/pFSIoqJkx/2x5O.WmKBLvWTKW8gDoCVS9tutPWpa2Cd7a.', 0, '2026-07-28 10:51:48', '2026-07-28 10:51:48', NULL)
		ON DUPLICATE KEY UPDATE
			username=VALUES(username),
			email=VALUES(email),
			password=VALUES(password),
			isadmin=VALUES(isadmin),
			created_at=VALUES(created_at),
			updated_at=VALUES(updated_at),
			deleted_at=VALUES(deleted_at);

		INSERT INTO ad_vault.agents
			(id, agent_id, forward_security_key, expiry_in_seconds, enforce_forward_security_key, created_at, updated_at, deleted_at)
		VALUES
			(1, 'VaultAgent1', 'VaultAgent1Key', 86400, 1, NULL, NULL, NULL)
		ON DUPLICATE KEY UPDATE
			agent_id=VALUES(agent_id),
			forward_security_key=VALUES(forward_security_key),
			expiry_in_seconds=VALUES(expiry_in_seconds),
			enforce_forward_security_key=VALUES(enforce_forward_security_key),
			created_at=VALUES(created_at),
			updated_at=VALUES(updated_at),
			deleted_at=VALUES(deleted_at);

		COMMIT;
	"; then
		ERRORmsg "Failed to add required ad_vault users or agent"
		return 1
	fi

	log "Adding required ad_vault users and agent DONE"
	return 0
}

EXPORT_MYSQL_FULL_DUMP() {
	log "Preparing export..."

	rm -rf "${SANI_DUMP_DIR}/"
	mkdir -p "${SANI_DUMP_DIR}"

	rm -f "${SANI_DUMP_OLD_TAR_GZ}" "${SANI_DUMP_OLD_TAR}" "${SANI_DUMP_TGZ}"

	if [ "${DELETE_SOURCE_BACKUP}" = "1" ]; then
		log "Deleting original source dump to free disk space..."
# 		rm -rf "${SOURCE_DUMP_DIR:?}/"*
	else
		log "DELETE_SOURCE_BACKUP=0 — keeping original source backup."
	fi

	df -h | tee -a "$Logfile"

	log "MySQL DATA DIR size:"
	du -sh "${MYSQL_DATA_DIR}/" | tee -a "$Logfile"

	log "Current shell open files limit: $(ulimit -n)"
	log "Running xtrabackup backup..."

	xtrabackup \
		--user="${MYSQL_ROOT_USER}" \
		--password="${MYSQL_ROOT_PASS}" \
		--host=localhost \
		--open-files-limit="${XTRABACKUP_OPEN_FILES_LIMIT}" \
		--parallel="${XTRABACKUP_BACKUP_PAR}" \
		--backup \
		--datadir="${MYSQL_DATA_DIR}/" \
		--target-dir="${SANI_DUMP_DIR}/" \
		2>&1 | tee "${XTRABACKUP_BACKUP_LOG}"

	if [ "${PIPESTATUS[0]}" -ne 0 ]; then
		ERRORmsg "xtrabackup backup failed. Check ${XTRABACKUP_BACKUP_LOG}"
		return 1
	fi

	if [ ! -s "${SANI_DUMP_DIR}/xtrabackup_checkpoints" ]; then
		ERRORmsg "xtrabackup output invalid/empty. Missing ${SANI_DUMP_DIR}/xtrabackup_checkpoints"
		return 1
	fi

	log "Running xtrabackup prepare..."

	xtrabackup \
		--prepare \
		--target-dir="${SANI_DUMP_DIR}" \
		2>&1 | tee "${XTRABACKUP_PREPARE_LOG}"

	if [ "${PIPESTATUS[0]}" -ne 0 ]; then
		ERRORmsg "xtrabackup prepare failed. Check ${XTRABACKUP_PREPARE_LOG}"
		return 1
	fi

	log "Generating MD5 hashes..."

	find "${SANI_DUMP_DIR}/" -type f -exec md5sum {} + > "${MD5_TMP}"
	sed "s| ${SANI_DUMP_DIR}/||g" "${MD5_TMP}" > "${MD5_TMP_CLEANED}"
	rm -f "${MD5_TMP}"
	mv "${MD5_TMP_CLEANED}" "${MD5_FINAL}"

	log "Sanitized dump dir size:"
	du -sh "${SANI_DUMP_DIR}/" | tee -a "$Logfile"

	log "Creating ${SANI_DUMP_TGZ}..."

	cd "$(dirname "${SANI_DUMP_TGZ}")" || return 1
	if command -v pigz >/dev/null 2>&1; then
		log "Using pigz with ${ARCHIVE_PAR} parallel compression threads..."
		tar --use-compress-program="pigz -p ${ARCHIVE_PAR}" \
			-cf "$(basename "${SANI_DUMP_TGZ}")" "$(basename "${SANI_DUMP_DIR}")"
	else
		log "pigz is unavailable; using standard gzip compression."
		tar zcf "$(basename "${SANI_DUMP_TGZ}")" "$(basename "${SANI_DUMP_DIR}")"
	fi

	if [ "$?" -ne 0 ]; then
		ERRORmsg "tar creation failed"
		return 1
	fi

	chmod a+r "${SANI_DUMP_TGZ}"

	if [ "${SHIP_TO_REMOTE}" = "1" ]; then
		log "Shipping dump to ${REMOTE_HOST}..."

		ssh "${SSH_TARGET}" "rm -rf ${REMOTE_DUMP_DIR}/*"
		scp -c "${SCP_CIPHER}" -pr "${SANI_DUMP_DIR}"/* "${SSH_TARGET}:${REMOTE_DUMP_DIR}/"
		rsync -av --timeout=60 --delete --dry-run "${SANI_DUMP_DIR}"/* "${SSH_TARGET}:${REMOTE_DUMP_DIR}/" | tee -a "$Logfile"
	else
		log "SHIP_TO_REMOTE=0 — skipping remote ship phase."
	fi

	if [ "${MOVE_TGZ_TO_SHAREME}" = "1" ]; then
		log "Moving ${SANI_DUMP_TGZ} to ${SHAREME_DUMP_TGZ}"
		mv "${SANI_DUMP_TGZ}" "${SHAREME_DUMP_TGZ}"
	else
		log "MOVE_TGZ_TO_SHAREME=0 — leaving tgz at ${SANI_DUMP_TGZ}"
	fi

	rm -rf "${SANI_DUMP_DIR}/"
	sync

	df -h | tee -a "$Logfile"

	return 0
}

CLEAR_SYSTEM_CACHE() {
	sync
	echo 3 > /proc/sys/vm/drop_caches || true
	return 0
}

FAILED_SANITIZE_PHASES=()

RUN_SANITIZE_PHASE() {
	local label="$1"
	local function_name="$2"

	log "Starting sanitize phase: ${label}"
	if "${function_name}"; then
		log "Sanitize phase succeeded: ${label}"
	else
		ERRORmsg "Sanitize phase FAILED: ${label}"
		FAILED_SANITIZE_PHASES+=("${label}")
	fi
}

if [ "${RUN_MODE}" != "full" ]; then
	echo "$(date) - ${RUN_MODE} started" | tee -a "$Logfile"
	echo "$(date) - ${RUN_MODE} diagnostic log started" >> "$ERROR_LOG"
else
	echo "$(date) - Started" | tee "$Logfile"
	echo "$(date) - Diagnostic log started" > "$ERROR_LOG"
fi

mkdir -p "${DESTINATION}"

case "${RUN_MODE}" in
	full)
		STOPPING_MYSQL_SERVER || exit 1
		COPYING_MYSQL_FILES || exit 1
		STARTING_MYSQL_SERVER || exit 1
		CHECK_SQL_AUTHENTICATION || exit 1
		CREATE_EMAIL_HASH_FUNCTION || exit 1

		TRUNCATE_CONFIGURED_TABLES || exit 1
		TRUNCATE_ALERT_CORE_AUDIT_TABLES || exit 1
		APPLY_REVIEW_RESEEDS || exit 1

		log "Phase 2: running sanitize jobs..."
		RUN_SANITIZE_PHASE "Keycloak" SANITIZE_KEYCLOAK
		RUN_SANITIZE_PHASE "reports" SANITIZE_REPORTS
		# These older broad truncation functions intentionally remain disabled.
		# TRUNCATE_CONFIGURED_TABLES contains the complete approved truncation list.
		SANITIZE_AD_VAULT_TABLES
		# WIPE_OUT_MYSQL_FD_LMS_SESSIONS
		RUN_SANITIZE_PHASE "email columns" SANITIZE_EMAILS
		RUN_SANITIZE_PHASE "names, addresses, and phone numbers" SANITIZE_PERSONAL_DATA
		RUN_SANITIZE_PHASE "password columns" SANITIZE_PASSWORDS
		RUN_SANITIZE_PHASE "fd_lms_extra_services credentials" UPDATE_FD_LMS_EXTRA_SERVICES
		RUN_SANITIZE_PHASE "SanitizationReview final updates" APPLY_REVIEW_FINAL_UPDATES

		if [ "${#FAILED_SANITIZE_PHASES[@]}" -ne 0 ]; then
			failed_phase_list=$(IFS=', '; echo "${FAILED_SANITIZE_PHASES[*]}")
			ERRORmsg "Failed sanitize phases: ${failed_phase_list}. Aborting before export."
			exit 1
		fi
		;;
	resume-aperture)
		log "RUN_MODE=resume-aperture: preserving the current MySQL data directory."
		CHECK_SQL_AUTHENTICATION || exit 1
		CREATE_EMAIL_HASH_FUNCTION || exit 1
		RESUME_APERTURE_EMAIL || exit 1
		;;
	resume-email)
		log "RUN_MODE=resume-email: preserving the current MySQL data directory and retrying all email columns only."
		CHECK_SQL_AUTHENTICATION || exit 1
		CREATE_EMAIL_HASH_FUNCTION || exit 1
		SANITIZE_EMAILS || exit 1
		;;
	finalize)
		log "RUN_MODE=finalize: preserving the current database and continuing after completed sanitization phases."
		CHECK_SQL_AUTHENTICATION || exit 1
		CREATE_EMAIL_HASH_FUNCTION || exit 1
		APPLY_REVIEW_FINAL_UPDATES || exit 1
		;;
	*)
		ERRORmsg "Invalid RUN_MODE '${RUN_MODE}'. Use 'full', 'resume-aperture', 'resume-email', or 'finalize'."
		exit 1
		;;
esac

if [ "${RUN_MODE}" = "resume-aperture" ]; then
	APPLY_REVIEW_FINAL_UPDATES || exit 1
fi

DROP_EMAIL_HASH_FUNCTION || exit 1

UPDATE_FD_COMPANY_REPORT_FTP || exit 1

CLEAR_SYSTEM_CACHE

CLEANUP_SANITIZE_DATA || exit 1

DUMP_STRUCTURES || exit 1

SANITIZE_MYSQL_USERS || exit 1

RECREATE_MONITOR_PROXYSQL_USERS || exit 1

ADD_REQUIRED_AD_VAULT_ROWS || exit 1

EXPORT_MYSQL_FULL_DUMP || exit 1

CLEAR_SYSTEM_CACHE

echo "------------------------------------------------------------------------------------" | tee -a "$Logfile"
log "MySQL sanitization DONE"
echo "------------------------------------------------------------------------------------" | tee -a "$Logfile"

exit 0

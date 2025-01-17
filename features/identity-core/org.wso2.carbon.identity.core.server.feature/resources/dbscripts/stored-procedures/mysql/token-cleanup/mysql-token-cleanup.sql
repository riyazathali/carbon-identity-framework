DROP PROCEDURE IF EXISTS `WSO2_TOKEN_CLEANUP_SP`;

DELIMITER $$

CREATE PROCEDURE `WSO2_TOKEN_CLEANUP_SP`()

BEGIN

-- ------------------------------------------
-- DECLARE VARIABLES
-- ------------------------------------------
DECLARE batchSize INT;
DECLARE chunkSize INT;
DECLARE checkCount INT;
DECLARE backupTables BOOLEAN;
DECLARE sleepTime FLOAT;
DECLARE safePeriod INT;
DECLARE deleteTillTime DATETIME;
DECLARE rowCount INT;
DECLARE enableLog BOOLEAN;
DECLARE logLevel VARCHAR(10);
DECLARE enableAudit BOOLEAN;
DECLARE maxValidityPeriod BIGINT;
DECLARE anlyzeTables BOOLEAN;
DECLARE cursorTable VARCHAR(255);
DECLARE BACKUP_TABLE VARCHAR(255);
DECLARE cursorLoopFinished INTEGER DEFAULT 0;

DECLARE backupTablesCursor CURSOR FOR
SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA in (SELECT DATABASE()) AND
TABLE_NAME IN ('IDN_OAUTH2_ACCESS_TOKEN','IDN_OAUTH2_ACCESS_TOKEN_SCOPE','IDN_OIDC_REQ_OBJECT_REFERENCE','IDN_OIDC_REQ_OBJECT_CLAIMS','IDN_OIDC_REQ_OBJ_CLAIM_VALUES','IDN_OAUTH2_AUTHORIZATION_CODE');

DECLARE CONTINUE HANDLER FOR NOT FOUND SET cursorLoopFinished = 1;

-- ------------
SET maxValidityPeriod = 99999999999990;  -- IF THE VALIDITY PERIOD IS MORE THAN 3170.97 YEARS WILL SKIP THE CLEANUP PROCESS;
-- ------------
-- -----------------------------------------
-- CONFIGURABLE ATTRIBUTES
-- ------------------------------------------
SET batchSize = 10000;      -- SET BATCH SIZE FOR AVOID TABLE LOCKS    [DEFAULT : 10000]
SET chunkSize = 500000;    -- SET TEMP TABLE CHUNK SIZE FOR AVOID TABLE LOCKS    [DEFAULT : 1000000]
SET checkCount = 100; -- SET CHECK COUNT FOR FINISH CLEANUP SCRIPT (CLEANUP ELIGIBLE TOKENS COUNT SHOULD BE HIGHER THAN checkCount TO CONTINUE) [DEFAULT : 100]
SET backupTables = TRUE;    -- SET IF TOKEN TABLE NEEDS TO BACKUP BEFORE DELETE     [DEFAULT : TRUE] , WILL DROP THE PREVIOUS BACKUP TABLES IN NEXT ITERATION
SET sleepTime = 2;          -- SET SLEEP TIME FOR AVOID TABLE LOCKS     [DEFAULT : 2]
SET safePeriod = 2;         -- SET SAFE PERIOD OF HOURS FOR TOKEN DELETE, SINCE TOKENS COULD BE CASHED    [DEFAULT : 2]
SET deleteTillTime = DATE_ADD(NOW(), INTERVAL -(safePeriod) HOUR);    -- SET CURRENT TIME - safePeriod FOR BEGIN THE TOKEN DELETE
SET rowCount=0;
SET enableLog = TRUE;       -- ENABLE LOGGING [DEFAULT : FALSE]
SET logLevel = 'TRACE';    -- SET LOG LEVELS : TRACE , DEBUG
SET enableAudit = FALSE;    -- SET TRUE FOR  KEEP TRACK OF ALL THE DELETED TOKENS USING A TABLE   [DEFAULT : FALSE] [IF YOU ENABLE THIS TABLE BACKUP WILL FORCEFULLY SET TO TRUE]
SET SQL_MODE='ALLOW_INVALID_DATES';                                -- MAKE THIS UNCOMMENT IF MYSQL THROWS "ERROR 1067 (42000): Invalid default value for 'TIME_CREATED'"
-- SET SESSION TRANSACTION ISOLATION LEVEL READ UNCOMMITTED ;      -- SET ISOLATION LEVEL TO AVOID TABLE LOCKS IN SELECT.
SET anlyzeTables = FALSE; -- SET TRUE FOR Analyze the tables TO IMPROVE QUERY PERFOMANCE [DEFAULT : FALSE]

IF (enableLog)
THEN
SELECT 'WSO2_TOKEN_CLEANUP_SP STARTED ... !' AS 'INFO LOG';
END IF;

IF (enableAudit)
THEN
SET backupTables = TRUE;    -- BACKUP TABLES IS REQUIRED HENCE THE AUDIT IS ENABLED.
END IF;


IF (backupTables)
THEN
      IF (enableLog)
      THEN
      SELECT 'TABLE BACKUP STARTED ... !' AS 'INFO LOG';
      END IF;

      OPEN backupTablesCursor;
      backupLoop: loop
              fetch backupTablesCursor into cursorTable;

              IF cursorLoopFinished = 1 THEN
              LEAVE backupLoop;
              END IF;

              SELECT CONCAT('BAK_',cursorTable) into BACKUP_TABLE;

                  SET @dropTab=CONCAT("DROP TABLE IF EXISTS ", BACKUP_TABLE);
                  PREPARE stmtDrop FROM @dropTab;
                  EXECUTE stmtDrop;
                  DEALLOCATE PREPARE stmtDrop;

              IF (enableLog AND logLevel IN ('TRACE'))
              THEN
                  SET @printstate=CONCAT("SELECT 'BACKING UP ",cursorTable," TOKENS INTO ", BACKUP_TABLE, " 'AS' TRACE LOG' , COUNT(1) FROM ", cursorTable);
                  PREPARE stmtPrint FROM @printstate;
                  EXECUTE stmtPrint;
                  DEALLOCATE PREPARE stmtPrint;
              END IF;

              SET @cretTab=CONCAT("CREATE TABLE ", BACKUP_TABLE," SELECT * FROM ",cursorTable);
              PREPARE stmtDrop FROM @cretTab;
              EXECUTE stmtDrop;
              DEALLOCATE PREPARE stmtDrop;

              IF (enableLog  AND logLevel IN ('DEBUG','TRACE') )
              THEN
              SET @printstate= CONCAT("SELECT 'BACKING UP ",BACKUP_TABLE," COMPLETED ! ' AS 'DEBUG LOG', COUNT(1) FROM ", BACKUP_TABLE);
              PREPARE stmtPrint FROM @printstate;
              EXECUTE stmtPrint;
              DEALLOCATE PREPARE stmtPrint;
              END IF;
      END loop backupLoop;
      CLOSE backupTablesCursor;
END IF;

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- CREATING AUDITLOG TABLES FOR DELETING TOKENS
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
IF (enableAudit)
THEN
    IF (NOT EXISTS (SELECT * FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'AUDITLOG_IDN_OAUTH2_ACCESS_TOKEN_CLEANUP' and TABLE_SCHEMA in (SELECT DATABASE())))
    THEN
        IF (enableLog AND logLevel IN ('TRACE')) THEN
        SELECT 'CREATING AUDIT TABLE AUDITLOG_IDN_OAUTH2_ACCESS_TOKEN_CLEANUP .. !';
        END IF;
        CREATE TABLE AUDITLOG_IDN_OAUTH2_ACCESS_TOKEN_CLEANUP SELECT * FROM IDN_OAUTH2_ACCESS_TOKEN WHERE 1 = 2;
    ELSE
        IF (enableLog AND logLevel IN ('TRACE')) THEN
        SELECT 'USING AUDIT TABLE AUDITLOG_IDN_OAUTH2_ACCESS_TOKEN_CLEANUP ..!';
        END IF;
    END IF;

    IF (NOT EXISTS (SELECT * FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'AUDITLOG_IDN_OAUTH2_AUTHORIZATION_CODE_CLEANUP' and TABLE_SCHEMA in (SELECT DATABASE())))
    THEN
        IF (enableLog AND logLevel IN ('TRACE')) THEN
        SELECT 'CREATING AUDIT TABLE AUDITLOG_IDN_OAUTH2_AUTHORIZATION_CODE_CLEANUP .. !';
        END IF;
        CREATE TABLE AUDITLOG_IDN_OAUTH2_AUTHORIZATION_CODE_CLEANUP SELECT * FROM IDN_OAUTH2_AUTHORIZATION_CODE WHERE 1 = 2;
    ELSE
        IF (enableLog AND logLevel IN ('TRACE')) THEN
        SELECT 'USING AUDIT TABLE AUDITLOG_IDN_OAUTH2_AUTHORIZATION_CODE_CLEANUP ..!';
        END IF;
    END IF;
END IF;


-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- CALCULATING TOKENS TYPES IN IDN_OAUTH2_ACCESS_TOKEN
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
IF (enableLog)
THEN
    SELECT 'CALCULATING TOKENS TYPES IN IDN_OAUTH2_ACCESS_TOKEN TABLE .... !' AS 'INFO LOG';

    IF (enableLog AND logLevel IN ('DEBUG','TRACE'))
    THEN
    SELECT  COUNT(1)  into rowcount FROM IDN_OAUTH2_ACCESS_TOKEN;
    SELECT 'TOTAL TOKENS ON IDN_OAUTH2_ACCESS_TOKEN TABLE BEFORE DELETE' AS 'DEBUG LOG',rowcount;
    END IF;

    IF (enableLog AND logLevel IN ('TRACE'))
    THEN
    SELECT COUNT(1) into @cleaupCount  FROM IDN_OAUTH2_ACCESS_TOKEN WHERE TOKEN_STATE IN ('INACTIVE','REVOKED','EXPIRED') OR (TOKEN_STATE IN ('ACTIVE') AND (VALIDITY_PERIOD > 0 AND VALIDITY_PERIOD < maxValidityPeriod ) AND (REFRESH_TOKEN_VALIDITY_PERIOD > 0 AND REFRESH_TOKEN_VALIDITY_PERIOD < maxValidityPeriod) AND ( deleteTillTime > DATE_ADD(TIME_CREATED , INTERVAL +(VALIDITY_PERIOD/60000) MINUTE)) AND (deleteTillTime > DATE_ADD(REFRESH_TOKEN_TIME_CREATED,INTERVAL +(REFRESH_TOKEN_VALIDITY_PERIOD/60000) MINUTE)));
    SELECT 'TOTAL TOKENS SHOULD BE DELETED FROM IDN_OAUTH2_ACCESS_TOKEN' AS 'TRACE LOG', @cleaupCount;
    END IF;

    IF (enableLog AND logLevel IN ('TRACE'))
    THEN
    set rowcount  = (rowcount - @cleaupCount);
    SELECT 'TOTAL TOKENS SHOULD BE RETAIN IN IDN_OAUTH2_ACCESS_TOKEN' AS 'TRACE LOG', rowcount;
    END IF;
END IF;

-- ------------------------------------------------------
-- BATCH DELETE IDN_OAUTH2_ACCESS_TOKEN
-- ------------------------------------------------------
IF (enableLog)
THEN
SELECT 'TOKEN DELETE ON IDN_OAUTH2_ACCESS_TOKEN STARTED .... !' AS 'INFO LOG';
END IF;

TOKE_CHUNK_LOOP: REPEAT

      IF (EXISTS (SELECT * FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'CHUNK_IDN_OAUTH2_ACCESS_TOKEN' and TABLE_SCHEMA in (SELECT DATABASE())))
      THEN
      DROP TEMPORARY TABLE CHUNK_IDN_OAUTH2_ACCESS_TOKEN;
      END IF;

      CREATE TEMPORARY TABLE CHUNK_IDN_OAUTH2_ACCESS_TOKEN SELECT TOKEN_ID FROM IDN_OAUTH2_ACCESS_TOKEN WHERE TOKEN_STATE IN ('INACTIVE','REVOKED','EXPIRED') OR (TOKEN_STATE IN ('ACTIVE') AND (VALIDITY_PERIOD > 0 AND VALIDITY_PERIOD < maxValidityPeriod ) AND (REFRESH_TOKEN_VALIDITY_PERIOD > 0 AND REFRESH_TOKEN_VALIDITY_PERIOD < maxValidityPeriod) AND ( deleteTillTime > DATE_ADD(TIME_CREATED , INTERVAL +(VALIDITY_PERIOD/60000) MINUTE)) AND (deleteTillTime > DATE_ADD(REFRESH_TOKEN_TIME_CREATED,INTERVAL +(REFRESH_TOKEN_VALIDITY_PERIOD/60000) MINUTE))) LIMIT chunkSize;

      SELECT COUNT(1) INTO @chunkCount FROM CHUNK_IDN_OAUTH2_ACCESS_TOKEN;

      IF (@chunkCount<checkCount)
      THEN
      LEAVE TOKE_CHUNK_LOOP;
      END IF;

      CREATE INDEX IDX_CHK_IDN_OATH_ACCSS_TOK ON CHUNK_IDN_OAUTH2_ACCESS_TOKEN(TOKEN_ID);

      IF (enableLog AND logLevel IN ('TRACE'))
      THEN
      SELECT 'PROCCESING CHUNK IDN_OAUTH2_ACCESS_TOKEN STARTED .... !' AS 'TRACE LOG',@chunkCount ;
      END IF;

      IF (enableAudit)
      THEN
      INSERT INTO AUDITLOG_IDN_OAUTH2_ACCESS_TOKEN_CLEANUP SELECT TOK.* FROM  IDN_OAUTH2_ACCESS_TOKEN AS TOK INNER JOIN  CHUNK_IDN_OAUTH2_ACCESS_TOKEN AS CHK WHERE TOK.TOKEN_ID = CHK.TOKEN_ID;
      END IF;


      TOKE_BATCH_LOOP: REPEAT
            IF (EXISTS (SELECT * FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'BATCH_IDN_OAUTH2_ACCESS_TOKEN' and TABLE_SCHEMA in (SELECT DATABASE())))
            THEN
            DROP TEMPORARY TABLE BATCH_IDN_OAUTH2_ACCESS_TOKEN;
            END IF;

            CREATE TEMPORARY TABLE BATCH_IDN_OAUTH2_ACCESS_TOKEN SELECT TOKEN_ID FROM CHUNK_IDN_OAUTH2_ACCESS_TOKEN LIMIT batchSize;

            SELECT COUNT(1) INTO @batchCount FROM BATCH_IDN_OAUTH2_ACCESS_TOKEN;

            IF (@batchCount=0 )
            THEN
            LEAVE TOKE_BATCH_LOOP;
            END IF;

            IF (enableLog AND logLevel IN ('TRACE'))
            THEN
            SELECT 'BATCH DELETE STARTED ON IDN_OAUTH2_ACCESS_TOKEN :' AS 'TRACE LOG',  @batchCount;
            END IF;

            DELETE A
            FROM IDN_OAUTH2_ACCESS_TOKEN AS A
            INNER JOIN BATCH_IDN_OAUTH2_ACCESS_TOKEN AS B
            ON A.TOKEN_ID = B.TOKEN_ID;

            SELECT row_count() INTO rowCount;

            IF (enableLog)
            THEN
            SELECT 'BATCH DELETE FINISHED ON IDN_OAUTH2_ACCESS_TOKEN :' AS 'INFO LOG', rowCount;
            END IF;

            DELETE A
            FROM CHUNK_IDN_OAUTH2_ACCESS_TOKEN AS A
            INNER JOIN BATCH_IDN_OAUTH2_ACCESS_TOKEN AS B
            ON A.TOKEN_ID = B.TOKEN_ID;

            IF ((rowCount > 0))
            THEN
            DO SLEEP(sleepTime);
            END IF;
      UNTIL rowCount=0 END REPEAT;
UNTIL @chunkCount=0 END REPEAT;

IF (enableLog )
THEN
SELECT 'TOKEN DELETE ON IDN_OAUTH2_ACCESS_TOKEN COMPLETED .... !' AS 'INFO LOG';
END IF;

-- ------------------------------------------------------
-- CALCULATING AUTHORIZATION_CODES ON IDN_OAUTH2_AUTHORIZATION_CODE
-- ------------------------------------------------------
IF (enableLog)
THEN
    SELECT 'CALCULATING AUTHORIZATION_CODES ON IDN_OAUTH2_AUTHORIZATION_CODE .... !' AS 'INFO LOG';

    IF (enableLog AND logLevel IN ('DEBUG','TRACE'))
    THEN
    SELECT  COUNT(1) into rowcount FROM IDN_OAUTH2_AUTHORIZATION_CODE;
    SELECT 'TOTAL TOKENS ON IDN_OAUTH2_AUTHORIZATION_CODE TABLE BEFORE DELETE' AS 'DEBUG LOG', rowcount;
    END IF;

    IF (enableLog AND logLevel IN ('TRACE'))
    THEN
    SELECT COUNT(1) into @cleaupCount FROM IDN_OAUTH2_AUTHORIZATION_CODE WHERE CODE_ID IN (SELECT CODE_ID FROM IDN_OAUTH2_AUTHORIZATION_CODE code WHERE NOT EXISTS ( SELECT * FROM IDN_OAUTH2_ACCESS_TOKEN tok where tok.TOKEN_ID = code.TOKEN_ID)) AND (((VALIDITY_PERIOD > 0 AND VALIDITY_PERIOD < maxValidityPeriod ) AND (deleteTillTime > DATE_ADD( TIME_CREATED , INTERVAL +(VALIDITY_PERIOD / 60000 ) MINUTE ))) OR STATE ='INACTIVE');
    SELECT 'TOTAL TOKENS ON SHOULD BE DELETED FROM IDN_OAUTH2_AUTHORIZATION_CODE' AS 'TRACE LOG', @cleaupCount;
    END IF;

    IF (enableLog AND logLevel IN ('TRACE'))
    THEN
    SET rowcount  = (rowcount - @cleaupCount);
    SELECT 'TOTAL TOKENS ON SHOULD BE RETAIN IN IDN_OAUTH2_AUTHORIZATION_CODE' AS 'TRACE LOG', rowcount;
    END IF;
END IF;


-- ------------------------------------------------------
-- BATCH DELETE IDN_OAUTH2_AUTHORIZATION_CODE
-- ------------------------------------------------------
IF (enableLog)
THEN
SELECT 'CODE DELETE ON IDN_OAUTH2_AUTHORIZATION_CODE STARTED .... !' AS 'INFO LOG';
END IF;

CODE_CHUNK_LOOP: REPEAT
        IF (EXISTS (SELECT * FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'CHUNK_IDN_OAUTH2_AUTHORIZATION_CODE' and TABLE_SCHEMA in (SELECT DATABASE())))
        THEN
        DROP TEMPORARY TABLE CHUNK_IDN_OAUTH2_AUTHORIZATION_CODE;
        END IF;

        CREATE TEMPORARY TABLE CHUNK_IDN_OAUTH2_AUTHORIZATION_CODE SELECT CODE_ID FROM IDN_OAUTH2_AUTHORIZATION_CODE WHERE CODE_ID IN (SELECT CODE_ID FROM IDN_OAUTH2_AUTHORIZATION_CODE code WHERE NOT EXISTS ( SELECT * FROM IDN_OAUTH2_ACCESS_TOKEN tok where tok.TOKEN_ID = code.TOKEN_ID)) AND (((VALIDITY_PERIOD > 0 AND VALIDITY_PERIOD < maxValidityPeriod ) AND (deleteTillTime > DATE_ADD( TIME_CREATED , INTERVAL +(VALIDITY_PERIOD / 60000 ) MINUTE ))) OR STATE ='INACTIVE') LIMIT chunkSize;

        SELECT COUNT(1) INTO @chunkCount FROM CHUNK_IDN_OAUTH2_AUTHORIZATION_CODE;

        IF (@chunkCount<checkCount )
        THEN
        LEAVE CODE_CHUNK_LOOP;
        END IF;

        IF (enableLog AND logLevel IN ('TRACE'))
        THEN
        SELECT 'PROCCESING CHUNK IDN_OAUTH2_AUTHORIZATION_CODE STARTED .... !' AS 'TRACE LOG',@chunkCount ;
        END IF;

        CREATE INDEX IDX_CHK_IDN_OAUTH2_AUTHORIZATION_CODE ON CHUNK_IDN_OAUTH2_AUTHORIZATION_CODE (CODE_ID);

        IF (enableAudit)
        THEN
        INSERT INTO AUDITLOG_IDN_OAUTH2_AUTHORIZATION_CODE_CLEANUP  SELECT CODE.* FROM  IDN_OAUTH2_AUTHORIZATION_CODE AS CODE INNER JOIN CHUNK_IDN_OAUTH2_AUTHORIZATION_CODE AS CHK ON CODE.CODE_ID = CHK.CODE_ID;
        END IF;

        CODE_BATCH_LOOP: REPEAT
                IF (EXISTS (SELECT * FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'BATCH_IDN_OAUTH2_AUTHORIZATION_CODE' and TABLE_SCHEMA in (SELECT DATABASE())))
                THEN
                DROP TEMPORARY TABLE BATCH_IDN_OAUTH2_AUTHORIZATION_CODE;
                END IF;

                CREATE TEMPORARY TABLE BATCH_IDN_OAUTH2_AUTHORIZATION_CODE SELECT CODE_ID FROM CHUNK_IDN_OAUTH2_AUTHORIZATION_CODE LIMIT batchSize;

                SELECT COUNT(1) INTO @batchCount FROM BATCH_IDN_OAUTH2_AUTHORIZATION_CODE;

                IF (@batchCount=0 )
                THEN
                LEAVE CODE_BATCH_LOOP;
                END IF;

                IF (enableLog AND logLevel IN ('TRACE'))
                THEN
                SELECT 'BATCH DELETE STARTED ON IDN_OAUTH2_AUTHORIZATION_CODE:' AS 'TRACE LOG', @batchCount;
                END IF;

                DELETE A
                FROM IDN_OAUTH2_AUTHORIZATION_CODE AS A
                INNER JOIN BATCH_IDN_OAUTH2_AUTHORIZATION_CODE AS B
                ON A.CODE_ID = B.CODE_ID;

                SELECT row_count() INTO rowCount;

                IF (enableLog)
                THEN
                SELECT 'BATCH DELETE FINISHED ON IDN_OAUTH2_AUTHORIZATION_CODE:' AS 'INFO LOG', rowCount;
                END IF;

                DELETE A
                FROM CHUNK_IDN_OAUTH2_AUTHORIZATION_CODE AS A
                INNER JOIN BATCH_IDN_OAUTH2_AUTHORIZATION_CODE AS B
                ON A.CODE_ID = B.CODE_ID;

                IF ((rowCount > 0))
                THEN
                DO SLEEP(sleepTime);
                END IF;
        UNTIL rowCount=0 END REPEAT;
UNTIL @chunkCount=0 END REPEAT;

IF (enableLog)
THEN
SELECT 'CODE DELETE ON IDN_OAUTH2_AUTHORIZATION_CODE COMPLETED .... !' AS 'INFO LOG';
END IF;
-- ------------------------------------------------------

IF (enableLog AND logLevel IN ('DEBUG','TRACE'))
THEN
SELECT 'TOTAL TOKENS ON IDN_OAUTH2_ACCESS_TOKEN TABLE AFTER DELETE' AS 'DEBUG LOG', COUNT(1) FROM IDN_OAUTH2_ACCESS_TOKEN;
END IF;

IF (enableLog AND logLevel IN ('DEBUG','TRACE'))
THEN
SELECT 'TOTAL TOKENS ON IDN_OAUTH2_AUTHORIZATION_CODE TABLE AFTER DELETE' AS 'DEBUG LOG', COUNT(1) FROM IDN_OAUTH2_AUTHORIZATION_CODE;
END IF;

-- ------------------------------------------------------
-- OPTIMIZING TABLES FOR BETTER PERFORMANCE
-- ------------------------------------------------------

IF (anlyzeTables)
THEN

    IF (enableLog)
    THEN
    SELECT 'TABLE ANALYZING STARTED .... !' AS 'INFO LOG';
    END IF;

    ANALYZE TABLE IDN_OAUTH2_ACCESS_TOKEN;
    ANALYZE TABLE IDN_OAUTH2_AUTHORIZATION_CODE;
    ANALYZE TABLE IDN_OAUTH2_ACCESS_TOKEN_SCOPE;

END IF;

IF (enableLog)
THEN
SELECT 'CLEANUP_OAUTH2_TOKENS() COMPLETED .... !' AS 'INFO LOG';
END IF;

END$$

DELIMITER ;

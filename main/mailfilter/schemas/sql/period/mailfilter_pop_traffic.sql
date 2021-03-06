CREATE TABLE IF NOT EXISTS mailfilter_pop_traffic (
        `date` TIMESTAMP NOT NULL,

        mails     BIGINT DEFAULT 0,
        clean     BIGINT DEFAULT 0,
        spam      BIGINT DEFAULT 0,
        virus     BIGINT DEFAULT 0,

        INDEX(`date`)
) ENGINE = MyISAM;

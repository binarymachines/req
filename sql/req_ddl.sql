CREATE TABLE "file_assets" (
  "id" uuid NOT NULL,
  "s3_uri" varchar(255) NOT NULL,
  "filename" varchar(32) NOT NULL,
  "source_url_base" varchar(64) NOT NULL,
  "source_url_path" varchar(64) NOT NULL,
  "source_metahash" varchar(255) NOT NULL,
  "created_ts" timestamp NOT NULL,
  "updated_ts" timestamp,
  "replaces_asset_id" uuid,
  PRIMARY KEY ("id")
);
CREATE UNIQUE INDEX "metahash_idx" ON "file_assets" USING btree (
  "source_metahash"
);
CREATE INDEX "filename_idx" ON "file_assets" USING btree (
  "filename"
);


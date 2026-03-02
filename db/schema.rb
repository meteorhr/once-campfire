# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.2].define(version: 2026_03_01_175000) do
  create_table "accounts", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "custom_styles"
    t.string "join_code", null: false
    t.string "name", null: false
    t.json "settings"
    t.integer "singleton_guard", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["singleton_guard"], name: "index_accounts_on_singleton_guard", unique: true
  end

  create_table "action_text_rich_texts", force: :cascade do |t|
    t.text "body"
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.datetime "updated_at", null: false
    t.index ["record_type", "record_id", "name"], name: "index_action_text_rich_texts_uniqueness", unique: true
  end

  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "bans", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["ip_address"], name: "index_bans_on_ip_address"
    t.index ["user_id"], name: "index_bans_on_user_id"
  end

  create_table "boosts", force: :cascade do |t|
    t.integer "booster_id", null: false
    t.string "content", limit: 16, null: false
    t.datetime "created_at", null: false
    t.integer "message_id", null: false
    t.datetime "updated_at", null: false
    t.index ["booster_id"], name: "index_boosts_on_booster_id"
    t.index ["message_id"], name: "index_boosts_on_message_id"
  end

  create_table "e2e_devices", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "device_id", null: false
    t.text "identity_key", null: false
    t.datetime "last_prekey_uploaded_at"
    t.string "name", null: false
    t.datetime "revoked_at"
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["user_id", "device_id"], name: "index_e2e_devices_on_user_id_and_device_id", unique: true
    t.index ["user_id", "revoked_at"], name: "index_e2e_devices_on_user_id_and_revoked_at"
    t.index ["user_id"], name: "index_e2e_devices_on_user_id"
  end

  create_table "e2e_message_envelopes", force: :cascade do |t|
    t.string "algorithm", null: false
    t.text "ciphertext", null: false
    t.string "client_message_id", null: false
    t.datetime "created_at", null: false
    t.datetime "delivered_at"
    t.json "header", default: {}, null: false
    t.integer "recipient_device_id", null: false
    t.integer "room_id", null: false
    t.integer "sender_device_id", null: false
    t.datetime "updated_at", null: false
    t.index ["recipient_device_id", "created_at"], name: "idx_e2e_message_envelopes_on_recipient_and_created"
    t.index ["recipient_device_id"], name: "index_e2e_message_envelopes_on_recipient_device_id"
    t.index ["room_id", "created_at"], name: "index_e2e_message_envelopes_on_room_id_and_created_at"
    t.index ["room_id"], name: "index_e2e_message_envelopes_on_room_id"
    t.index ["sender_device_id", "recipient_device_id", "client_message_id"], name: "idx_e2e_message_envelopes_unique_client_per_recipient", unique: true
    t.index ["sender_device_id"], name: "index_e2e_message_envelopes_on_sender_device_id"
  end

  create_table "e2e_one_time_prekeys", force: :cascade do |t|
    t.datetime "consumed_at"
    t.datetime "created_at", null: false
    t.integer "device_id", null: false
    t.integer "key_id", null: false
    t.text "public_key", null: false
    t.datetime "published_at", null: false
    t.datetime "updated_at", null: false
    t.index ["device_id", "consumed_at"], name: "index_e2e_one_time_prekeys_on_device_id_and_consumed_at"
    t.index ["device_id", "key_id"], name: "index_e2e_one_time_prekeys_on_device_id_and_key_id", unique: true
    t.index ["device_id"], name: "index_e2e_one_time_prekeys_on_device_id"
  end

  create_table "e2e_signed_prekeys", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.integer "device_id", null: false
    t.datetime "expires_at"
    t.integer "key_id", null: false
    t.text "public_key", null: false
    t.datetime "published_at", null: false
    t.text "signature", null: false
    t.datetime "updated_at", null: false
    t.index ["device_id", "active"], name: "index_e2e_signed_prekeys_on_device_id_and_active"
    t.index ["device_id", "key_id"], name: "index_e2e_signed_prekeys_on_device_id_and_key_id", unique: true
    t.index ["device_id"], name: "index_e2e_signed_prekeys_on_device_id"
  end

  create_table "memberships", force: :cascade do |t|
    t.datetime "connected_at"
    t.integer "connections", default: 0, null: false
    t.datetime "created_at", null: false
    t.string "involvement", default: "mentions"
    t.integer "room_id", null: false
    t.datetime "unread_at"
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["room_id", "created_at"], name: "index_memberships_on_room_id_and_created_at"
    t.index ["room_id", "user_id"], name: "index_memberships_on_room_id_and_user_id", unique: true
    t.index ["room_id"], name: "index_memberships_on_room_id"
    t.index ["user_id"], name: "index_memberships_on_user_id"
  end

  create_table "messages", force: :cascade do |t|
    t.string "client_message_id", null: false
    t.datetime "created_at", null: false
    t.integer "creator_id", null: false
    t.string "e2e_algorithm"
    t.json "e2e_payload"
    t.integer "room_id", null: false
    t.datetime "updated_at", null: false
    t.index ["creator_id"], name: "index_messages_on_creator_id"
    t.index ["room_id"], name: "index_messages_on_room_id"
  end

  create_table "push_subscriptions", force: :cascade do |t|
    t.string "auth_key"
    t.datetime "created_at", null: false
    t.string "endpoint"
    t.string "p256dh_key"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.integer "user_id", null: false
    t.index ["endpoint", "p256dh_key", "auth_key"], name: "idx_on_endpoint_p256dh_key_auth_key_7553014576"
    t.index ["user_id"], name: "index_push_subscriptions_on_user_id"
  end

  create_table "rooms", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "creator_id", null: false
    t.string "name"
    t.string "type", null: false
    t.datetime "updated_at", null: false
  end

  create_table "searches", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "query", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["user_id"], name: "index_searches_on_user_id"
  end

  create_table "sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.datetime "last_active_at", null: false
    t.string "token", null: false
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.integer "user_id", null: false
    t.index ["token"], name: "index_sessions_on_token", unique: true
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.text "bio"
    t.string "bot_token"
    t.datetime "created_at", null: false
    t.datetime "e2e_key_rotated_at"
    t.text "e2e_public_key"
    t.string "email_address"
    t.string "name", null: false
    t.string "password_digest"
    t.integer "role", default: 0, null: false
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["bot_token"], name: "index_users_on_bot_token", unique: true
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
  end

  create_table "webhooks", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "url"
    t.integer "user_id", null: false
    t.index ["user_id"], name: "index_webhooks_on_user_id"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "bans", "users"
  add_foreign_key "boosts", "messages"
  add_foreign_key "e2e_devices", "users"
  add_foreign_key "e2e_message_envelopes", "e2e_devices", column: "recipient_device_id"
  add_foreign_key "e2e_message_envelopes", "e2e_devices", column: "sender_device_id"
  add_foreign_key "e2e_message_envelopes", "rooms"
  add_foreign_key "e2e_one_time_prekeys", "e2e_devices", column: "device_id"
  add_foreign_key "e2e_signed_prekeys", "e2e_devices", column: "device_id"
  add_foreign_key "messages", "rooms"
  add_foreign_key "messages", "users", column: "creator_id"
  add_foreign_key "push_subscriptions", "users"
  add_foreign_key "searches", "users"
  add_foreign_key "sessions", "users"
  add_foreign_key "webhooks", "users"

  # Virtual tables defined in this database.
  # Note that virtual tables may not work with other database engines. Be careful if changing database.
  create_virtual_table "message_search_index", "fts5", ["body", "tokenize=porter"]
end

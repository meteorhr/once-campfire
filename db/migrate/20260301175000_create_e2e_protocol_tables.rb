class CreateE2eProtocolTables < ActiveRecord::Migration[8.2]
  def change
    create_table :e2e_devices do |t|
      t.references :user, null: false, foreign_key: true
      t.string :device_id, null: false
      t.string :name, null: false
      t.text :identity_key, null: false
      t.datetime :last_prekey_uploaded_at
      t.datetime :revoked_at

      t.timestamps
    end

    add_index :e2e_devices, [ :user_id, :device_id ], unique: true
    add_index :e2e_devices, [ :user_id, :revoked_at ]

    create_table :e2e_signed_prekeys do |t|
      t.references :device, null: false, foreign_key: { to_table: :e2e_devices }
      t.integer :key_id, null: false
      t.text :public_key, null: false
      t.text :signature, null: false
      t.datetime :published_at, null: false
      t.datetime :expires_at
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    add_index :e2e_signed_prekeys, [ :device_id, :key_id ], unique: true
    add_index :e2e_signed_prekeys, [ :device_id, :active ]

    create_table :e2e_one_time_prekeys do |t|
      t.references :device, null: false, foreign_key: { to_table: :e2e_devices }
      t.integer :key_id, null: false
      t.text :public_key, null: false
      t.datetime :published_at, null: false
      t.datetime :consumed_at

      t.timestamps
    end

    add_index :e2e_one_time_prekeys, [ :device_id, :key_id ], unique: true
    add_index :e2e_one_time_prekeys, [ :device_id, :consumed_at ]

    create_table :e2e_message_envelopes do |t|
      t.references :room, null: false, foreign_key: true
      t.references :sender_device, null: false, foreign_key: { to_table: :e2e_devices }
      t.references :recipient_device, null: false, foreign_key: { to_table: :e2e_devices }
      t.string :client_message_id, null: false
      t.string :algorithm, null: false
      t.json :header, null: false, default: {}
      t.text :ciphertext, null: false
      t.datetime :delivered_at

      t.timestamps
    end

    add_index :e2e_message_envelopes, [ :room_id, :created_at ]
    add_index :e2e_message_envelopes, [ :recipient_device_id, :created_at ], name: :idx_e2e_message_envelopes_on_recipient_and_created
    add_index :e2e_message_envelopes, [ :sender_device_id, :recipient_device_id, :client_message_id ], unique: true, name: :idx_e2e_message_envelopes_unique_client_per_recipient
  end
end

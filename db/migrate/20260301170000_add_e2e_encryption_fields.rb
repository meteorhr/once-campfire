class AddE2eEncryptionFields < ActiveRecord::Migration[8.2]
  def change
    change_table :users, bulk: true do |t|
      t.text :e2e_public_key
      t.datetime :e2e_key_rotated_at
    end

    change_table :messages, bulk: true do |t|
      t.string :e2e_algorithm
      t.json :e2e_payload
    end
  end
end

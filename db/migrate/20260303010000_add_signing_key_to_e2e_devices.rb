class AddSigningKeyToE2eDevices < ActiveRecord::Migration[8.2]
  def change
    add_column :e2e_devices, :signing_key, :text
  end
end

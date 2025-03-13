class CreateUsers < ActiveRecord::Migration[6.1]
  def change
    create_table :users do |t|
      t.string :email, null: false
      t.string :google_name
      t.string :display_name
      t.string :profile_image_url
      t.timestamps
    end
  end
end

class CreateReservedWords < ActiveRecord::Migration[6.1]
  def change
    create_table :reserved_words do |t|
      t.string :name,  null: false
      t.string :email, null: false
      t.references :user, null: false, foreign_key: true

      t.timestamps
    end
  end
end

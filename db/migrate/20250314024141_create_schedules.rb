class CreateSchedules < ActiveRecord::Migration[6.1]
  def change
    create_table :schedules do |t|
      t.string :summary, null: false
      t.date :start_time, null: false
      t.date :end_time, null: false
      t.references :user, null: false, foreign_key: true
      t.timestamps
    end
  end
end

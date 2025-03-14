class AddNlpInputAndIsopenToSchedules < ActiveRecord::Migration[6.1]
  def change
    add_column :schedules, :nlp_input, :string
    add_column :schedules, :isopen, :boolean, default: false, null: false
  end
end

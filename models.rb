require 'bundler/setup'
Bundler.require

ActiveRecord::Base.establish_connection

# タイムゾーンの設定
Time.zone = 'Tokyo'
ActiveRecord::Base.default_timezone = :local
# models/user.rb

class User < ActiveRecord::Base
  has_many :schedules, dependent: :destroy
end
class Schedule < ActiveRecord::Base
  belongs_to :user

  validates :summary, presence: true
  validates :start_time, presence: true
  validates :end_time, presence: true
  validates :user, presence: true
end
require 'bundler/setup'
Bundler.require

ActiveRecord::Base.establish_connection

# タイムゾーンの設定
Time.zone = 'Tokyo'
ActiveRecord::Base.default_timezone = :local
class User < ActiveRecord::Base
  has_many :schedules, dependent: :destroy
  has_many :comments, dependent: :destroy 
  has_many :likes
  has_many :liked_schedules, through: :likes, source: :schedule
  has_many :reserved_words, dependent: :destroy
end
class Schedule < ActiveRecord::Base
  belongs_to :user
  has_many :likes
  has_many :liked_users, through: :likes, source: :user
  has_many :comments, dependent: :destroy 
  validates :summary, presence: true
  validates :start_time, presence: true
  validates :end_time, presence: true
  validates :user, presence: true
end
class Like < ActiveRecord::Base
  belongs_to :user
  belongs_to :schedule
end
class Comment < ActiveRecord::Base
  belongs_to :user
  belongs_to :schedule
end
class Comment < ActiveRecord::Base
  belongs_to :user
  belongs_to :schedule
end

class ReservedWord < ActiveRecord::Base
  belongs_to :user

  validates :name,  presence: true
  validates :email, presence: true
end


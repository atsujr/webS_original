require 'bundler/setup'
Bundler.require

ActiveRecord::Base.establish_connection

# タイムゾーンの設定
Time.zone = 'Tokyo'
ActiveRecord::Base.default_timezone = :local
# models/user.rb

class User < ActiveRecord::Base
  # この中にロジックを記述
end

# app.rb
require 'sinatra'
require 'sinatra/reloader' if development?
require 'google/apis/calendar_v3'
require 'google/api_client/client_secrets'
require 'googleauth'
require 'googleauth/stores/file_token_store'
require 'fileutils'
require 'erb'
require 'time'       # Time.parse などを使う
require 'json'
require 'net/http'
require 'uri'
require 'openai'     # 追加
require 'dotenv'
require './models'
require 'cloudinary' 
require 'cloudinary/uploader'
require 'cloudinary/utils'
require 'active_support/all'  # Railsを使っていない場合、必要

set :bind, '0.0.0.0'
enable :sessions

# Google カレンダーAPIのスコープ
OAUTH_SCOPE = [
  'https://www.googleapis.com/auth/calendar',
  'https://www.googleapis.com/auth/userinfo.email',
  'https://www.googleapis.com/auth/userinfo.profile'
].join(' ')

Dotenv.load
# 環境変数を取得
CLIENT_ID     = ENV['CLIENT_ID']
CLIENT_SECRET = ENV['CLIENT_SECRET']
REDIRECT_URI  = ENV['REDIRECT_URI']
OPENAI_API_KEY = ENV['OPENAI_API_KEY']
# Cloudinary 設定
Cloudinary.config do |config|
  config.cloud_name = ENV['CLOUD_NAME']
  config.api_key    = ENV['CLOUDINARY_API_KEY']
  config.api_secret = ENV['CLOUDINARY_API_SECRET']
end

before do
    login_check unless request.path_info == '/login' || request.path_info == '/auth' || request.path_info == '/auth/callback'
    @authorized = session[:user_display_name] ? true : false
    @user = User.find_by(id: session[:user_id]) if session[:user_id]
end
# トップページ
get '/' do
  @schedules = Schedule.order(created_at: :desc)
  @posted = false
  p "モーダルを表示するか？"
  p @posted
  erb :index
end
get '/login' do
  erb :login
end
# (1) 初回ログイン用のOAuthリクエスト
get '/auth' do
  auth_client = build_oauth_client_for_login
  authorization_uri = auth_client.authorization_uri(
    access_type: 'offline',
    include_granted_scopes: 'true'
  )
  redirect authorization_uri.to_s
end

get '/auth/callback' do
  auth_client = build_oauth_client_for_login
  auth_client.code = params[:code]
  auth_client.fetch_access_token!

  session[:access_token]  = auth_client.access_token
  session[:refresh_token] = auth_client.refresh_token
  session[:expires_at]    = auth_client.expires_at

  # ユーザー情報を取得
  uri = URI.parse("https://www.googleapis.com/oauth2/v1/userinfo?alt=json")
  req = Net::HTTP::Get.new(uri)
  req["Authorization"] = "Bearer #{auth_client.access_token}"

  res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
    http.request(req)
  end
  userinfo = JSON.parse(res.body)

  email    = userinfo["email"]
  g_name   = userinfo["name"]      # Googleアカウントの名前
  g_pic    = userinfo["picture"]   # Googleアカウントのプロフィール画像URL

  # DBにユーザーがいれば取得、いなければ作成
  user = User.find_or_create_by(email: email)
  session[:user_id]   = user.id
  session[:user_email] = email
  if user.display_name.nil? || user.display_name.strip == ""
    user.google_name         = g_name unless g_name.nil?
    user.email              = email
    user.save
    redirect '/profile_setup'
  else
    # 既に設定済みなら通常のメイン画面へ
    session[:user_id]   = user.id
    p "ユーザ-ID"
    p session[:user_id]
    session[:user_display_name] = user.display_name
    # session[:user_profile_image_url] = user.profile_image_url
    redirect '/'
  end
end
# 表示名やプロフィール画像の設定フォームを表示
get '/profile_setup' do
  # ログイン中のユーザーを取ってくる
  @user = User.find(session[:user_id])
  
  erb :profile_setup
end

# フォームから送信された表示名とプロフィール画像をDBに保存
post '/profile_setup' do
  user = User.find(session[:user_id])

  # フォームからの値
  new_display_name = params[:display_name]
  
  if params[:profile_image]
    image = params[:profile_image]  # ファイル情報を取得
    tempfile = image[:tempfile]     # 一時ファイルパスを取得
    upload = Cloudinary::Uploader.upload(tempfile.path)  # Cloudinary にアップロード
    img_url = upload['url']  # アップロードされた画像のURLを取得
    user.profile_image_url = img_url
  else
    user.profile_image_url = "/img/logo.png" 
  end
  user.display_name = new_display_name.strip if new_display_name
  session[:user_display_name] = user.display_name
  user.save

  redirect '/'
end
# 自分の予定を確認するページ
get '/schedule' do
  @user = User.find(session[:user_id])
  @schedules = @user.schedules.order(created_at: :desc)  # ユーザーの予定を取得
  erb :myschedule
end

post '/schedules/:id/like' do
  # 例: ログイン中ユーザーを current_user として扱う
  #     すでにいいね済みかのチェックを入れたい場合は下記に条件分岐を追加してください。
  schedule = Schedule.find(params[:id])
  schedule.likes.create(user_id: @user.id)  # いいねを新規作成
  redirect '/'
end

########################################
# 自然言語入力から予定を追加するためのルート
########################################
post '/add_event_by_nlp' do
  client = get_google_client
  unless client
    redirect '/'
  end

  nlp_input = params[:nlp_input]
  if nlp_input.nil? || nlp_input.strip == ""
    @message_title = "予定の追加に失敗しました。"
    @message = "入力が空です。"
    @posted = true
    return erb :result
  end

  # ChatGPT API を呼び出して情報を抽出
  extracted_info = call_chatgpt_and_extract_info(nlp_input)
  if extracted_info.nil?
    @message_title = "予定の追加に失敗しました。"
    @message = "ChatGPT から有効な情報を取得できませんでした。"
    @posted = true
    return erb :result
  end

  summary     = extracted_info[:summary]     || "予定"
  description = extracted_info[:description] || ""
  start_time  = extracted_info[:start_time]  || (Time.now + 3600)
  end_time    = extracted_info[:end_time]    || (Time.now + 7200)
  is_open     = extracted_info[:is_open]     || false
  color       = (extracted_info[:color]      || 1).to_s
  # ここでattendeesを取得
  attendees_emails = extracted_info[:attendees] || []

  # Googleカレンダー用に、EventAttendeeの配列を組み立てる
  event_attendees = attendees_emails.map do |email|
    Google::Apis::CalendarV3::EventAttendee.new(email: email)
  end

  event = Google::Apis::CalendarV3::Event.new(
    summary: summary,
    description: description,
    start: Google::Apis::CalendarV3::EventDateTime.new(
      date_time: start_time.iso8601,
      time_zone: 'Asia/Tokyo'
    ),
    end: Google::Apis::CalendarV3::EventDateTime.new(
      date_time: end_time.iso8601,
      time_zone: 'Asia/Tokyo'
    ),
    color_id: color,
    attendees: event_attendees
  )

  service = Google::Apis::CalendarV3::CalendarService.new
  service.authorization = client

  begin
    # Googleカレンダーに登録
    result = service.insert_event('primary', event)

    # 画面表示用のメッセージ
    @message_title = "以下の予定がGoogleカレンダーに追加されました。"
    @message = "予定の内容: #{result.summary}\n" \
               "開始日時: #{result.start.date_time.in_time_zone('Asia/Tokyo').strftime('%Y年%m月%d日 %H時%M分')}\n" \
               "終了日時: #{result.end.date_time.in_time_zone('Asia/Tokyo').strftime('%Y年%m月%d日 %H時%M分')}"

    # DBにも保存
    user = User.find(session[:user_id])
    schedule = user.schedules.create(
      summary:     result.summary,
      start_time:  result.start.date_time, 
      end_time:    result.end.date_time,
      nlp_input:   nlp_input,
      isopen:      is_open
    )

    unless schedule.persisted?
      p "予定の保存に失敗しました: #{schedule.errors.full_messages}"
    end
  rescue => e
    @message_title = "予定の追加に失敗しました。"
    @message = "イベント追加に失敗しました: #{e.message}"
  end

  @posted = true
  @schedules = Schedule.order(created_at: :desc)
  erb :index
end
  
get '/schedules/:id/comment' do
  @schedule = Schedule.find(params[:id])
  @comments = @schedule.comments.order(created_at: :desc)
  erb :comment
end
post '/schedules/:id/comment' do

  schedule = Schedule.find(params[:id])
  comment = schedule.comments.new(
    user_id: @user.id,
    content: params[:content]
  )
  if comment.save
    p comment
  end 
  redirect "/schedules/#{params[:id]}/comment"
end
get '/reserved_words' do
  @user = User.find(session[:user_id])
  @reserved_words = @user.reserved_words.order(created_at: :desc)
  erb :reserved_words_index
end
# 新規登録
post '/reserved_words' do
  user = User.find(session[:user_id])
  rw = user.reserved_words.new(
    name:  params[:name],
    email: params[:email]
  )
  if rw.save
    redirect '/reserved_words'
  else
    @error_messages = rw.errors.full_messages
    erb :reserved_words_new
  end
end
########################################
# ChatGPT API を呼び出して情報抽出するためのメソッド
########################################
def call_chatgpt_and_extract_info(text)
  return nil if OPENAI_API_KEY.nil? || OPENAI_API_KEY.strip == ""

  # 現在の日本時間を取得
  now = Time.now.getlocal("+09:00")
  today_date = now.strftime("%Y-%m-%d")
  current_time = now.strftime("%H:%M:%S")

  # ここで予約語をDBから取得して文字列化
  reserved_words = ReservedWord.all
  # 例： "ともや -> tomoya@example.com\nけんじ -> kenji@test.com"
  reserved_words_str = reserved_words.map{|rw| "#{rw.name} -> #{rw.email}" }.join("\n")

  client = OpenAI::Client.new(access_token: OPENAI_API_KEY)
  
  # システムプロンプトに予約語一覧を追加
  system_content = <<~EOS
    あなたは予定作成アシスタントです。以下のユーザーの自然言語テキストから、
    予定のタイトル(summary)、開始日時(start_time)、終了日時(end_time)、説明(description)、
    予約語に該当する人たちの招待メール(attendees)を抽出してください。

    日本時間（Asia/Tokyo）を想定しています。
    日付や時刻が指定されていなかった場合、フィールドは空でもかまいません。

    **現在のリクエスト日時は以下の通りです。**
    - 今日の日付: #{today_date}
    - 現在の時刻: #{current_time}
    - 日付が「今日」「明日」「明後日」のように指定されている場合は、上記の日付を基準に計算してください。
    - 終了時間の記載がない場合は、開始時間から1時間後の時間を計算し、終了時間に設定してください。
    - 文章の最後に[非公開]のプロンプトがあった場合はisopenフィールドにtrueを設定してください。
    - colorフィールドは以下の1~11の整数のいずれかを設定してください。特に指定がない場合は1としてください。

    また、以下が「予約語一覧」です。ユーザーが自然言語の中でこの名前を出していた場合は、
    "attendees"フィールドに対応するメールアドレスを配列で追加してください。

    #{reserved_words_str}

    出力は必ず JSON のみで、以下の形式に従ってください。
    {
      "summary": "会議",
      "start_time": "2025-03-07T10:00:00+09:00",
      "end_time": "2025-03-07T11:00:00+09:00",
      "description": "田中さんとオンラインで",
      "isopen": true,
      "color": 3,
      "attendees": ["tomoya@example.com", "kenji@test.com"]
    }
  EOS

  user_content = text

  response = client.chat(
    parameters: {
      model: "gpt-4",  # ここは実際に使うモデルに合わせる
      messages: [
        { role: "system", content: system_content },
        { role: "user",   content: user_content }
      ],
      temperature: 0.2,
    }
  )

  content = response.dig("choices", 0, "message", "content")
  return nil if content.nil?

  begin
    json_data = JSON.parse(content)

    summary     = json_data["summary"]
    description = json_data["description"]
    start_time_str = json_data["start_time"]
    end_time_str   = json_data["end_time"]
    is_open        = json_data["isopen"]
    color          = json_data["color"]
    attendees      = json_data["attendees"]  # ChatGPTが抽出したメールの配列

    start_time = start_time_str && !start_time_str.empty? ? Time.parse(start_time_str) : nil
    end_time   = end_time_str   && !end_time_str.empty?   ? Time.parse(end_time_str)   : nil

    {
      summary: summary,
      description: description,
      start_time: start_time,
      end_time: end_time,
      is_open: is_open,
      color: color,
      attendees: attendees
    }
  rescue => e
    p e.message
    return nil
  end
end


# 初回ログイン用（まだアクセストークンが無い状態）のクライアント生成
def build_oauth_client_for_login
  client_secrets = Google::APIClient::ClientSecrets.new({
    "web" => {
      "client_id" => CLIENT_ID,
      "client_secret" => CLIENT_SECRET,
      "redirect_uris" => [REDIRECT_URI],
      "auth_uri" => "https://accounts.google.com/o/oauth2/auth",
      "token_uri" => "https://accounts.google.com/o/oauth2/token"
    }
  })

  auth_client = client_secrets.to_authorization
  auth_client.update!(
    scope: OAUTH_SCOPE,
    redirect_uri: REDIRECT_URI
  )
  auth_client
end

# セッション内にあるアクセストークン情報を使うクライアント生成
def get_google_client
  return nil if session[:access_token].nil?

  client_secrets = Google::APIClient::ClientSecrets.new({
    "web" => {
      "client_id" => CLIENT_ID,
      "client_secret" => CLIENT_SECRET,
      "redirect_uris" => [REDIRECT_URI],
      "auth_uri" => "https://accounts.google.com/o/oauth2/auth",
      "token_uri" => "https://accounts.google.com/o/oauth2/token"
    }
  })

  auth_client = client_secrets.to_authorization
  auth_client.update!(
    scope: OAUTH_SCOPE,
    redirect_uri: REDIRECT_URI,
    access_token: session[:access_token],
    refresh_token: session[:refresh_token],
    expires_at: session[:expires_at]
  )

  if auth_client.expired?
    auth_client.fetch_access_token!
    session[:access_token]  = auth_client.access_token
    session[:refresh_token] = auth_client.refresh_token
    session[:expires_at]    = auth_client.expires_at
  end

  auth_client
end
get '/logout' do
  session.clear 
  redirect '/login' 
end

private
    def login_check
        # ログインしていない場合ログイン画面に遷移させtrueを返す、ログインしている場合falseを返す
        return redirect '/login'  unless session[:user_email]
    end
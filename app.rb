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
set :bind, '0.0.0.0'
enable :sessions

# Google カレンダーAPIのスコープ
OAUTH_SCOPE = [
  'https://www.googleapis.com/auth/calendar',
  'https://www.googleapis.com/auth/userinfo.email',
  'https://www.googleapis.com/auth/userinfo.profile'
].join(' ')

# 必要な設定（GCPで取得した認証情報を記載）

Dotenv.load

# 環境変数を取得
CLIENT_ID     = ENV['CLIENT_ID']
CLIENT_SECRET = ENV['CLIENT_SECRET']
REDIRECT_URI  = ENV['REDIRECT_URI']
OPENAI_API_KEY = ENV['OPENAI_API_KEY']
# トップページ
get '/' do
  @authorized = session[:access_token] ? true : false
  @user_email = session[:user_email]
  @user_name  = session[:user_name]
  @user_picture  = session[:user_picture]
  erb :index
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

# (2) Google OAuth コールバック
get '/auth/callback' do
  auth_client = build_oauth_client_for_login
  auth_client.code = params[:code]
  auth_client.fetch_access_token!

  session[:access_token]  = auth_client.access_token
  session[:refresh_token] = auth_client.refresh_token
  session[:expires_at]    = auth_client.expires_at

  # ユーザー情報取得
  uri = URI.parse("https://www.googleapis.com/oauth2/v1/userinfo?alt=json")
  req = Net::HTTP::Get.new(uri)
  req["Authorization"] = "Bearer #{auth_client.access_token}"

  res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
    http.request(req)
  end
  userinfo = JSON.parse(res.body)

  session[:user_email]   = userinfo["email"]
  session[:user_name]    = userinfo["name"]
  session[:user_picture] = userinfo["picture"]  # プロフィール画像URL

  redirect '/'
end

# (3) 直接フォームから予定追加する既存のルート
post '/add_event' do
  client = get_google_client
  unless client
    redirect '/'
  end

  summary = params[:summary]
  start_time_obj = Time.parse("#{params[:start_time]} +09:00")
  end_time_obj   = Time.parse("#{params[:end_time]} +09:00")
  description = params[:description]

  event = Google::Apis::CalendarV3::Event.new(
    summary: summary,
    description: description,
    start: Google::Apis::CalendarV3::EventDateTime.new(
      date_time: start_time_obj.iso8601,
      time_zone: 'Asia/Tokyo'
    ),
    end: Google::Apis::CalendarV3::EventDateTime.new(
      date_time: end_time_obj.iso8601,
      time_zone: 'Asia/Tokyo'
    )
  )

  service = Google::Apis::CalendarV3::CalendarService.new
  service.authorization = client

  begin
    result = service.insert_event('primary', event)
    @message = "イベントを追加しました: #{result.summary}"
  rescue => e
    @message = "イベント追加に失敗しました: #{e.message}"
  end

  erb :result
end

########################################
# 自然言語入力から予定を追加するためのルート
########################################
post '/add_event_by_nlp' do
  client = get_google_client
  unless client
    redirect '/'
  end

  nlp_input = params[:nlp_input]  # ユーザーが入力した自然言語
  if nlp_input.nil? || nlp_input.strip == ""
    @message = "入力が空です。"
    return erb :result
  end

  # ChatGPT API を呼び出して情報を抽出する
  extracted_info = call_chatgpt_and_extract_info(nlp_input)

  if extracted_info.nil?
    @message = "ChatGPT から有効な情報を取得できませんでした。"
    return erb :result
  end

  # 抽出結果からカレンダーに登録
  summary = extracted_info[:summary] || "予定"
  description = extracted_info[:description] || ""
  # デフォルトとして今から1時間後などに設定してもよい
  start_time_obj = extracted_info[:start_time] || (Time.now + 3600)
  end_time_obj   = extracted_info[:end_time]   || (Time.now + 7200)

  event = Google::Apis::CalendarV3::Event.new(
    summary: summary,
    description: description,
    start: Google::Apis::CalendarV3::EventDateTime.new(
      date_time: start_time_obj.iso8601,
      time_zone: 'Asia/Tokyo'
    ),
    end: Google::Apis::CalendarV3::EventDateTime.new(
      date_time: end_time_obj.iso8601,
      time_zone: 'Asia/Tokyo'
    )
  )

  service = Google::Apis::CalendarV3::CalendarService.new
  service.authorization = client

  begin
    result = service.insert_event('primary', event)
    @message = "自然言語入力からイベントを追加しました: #{result.summary}"
  rescue => e
    @message = "イベント追加に失敗しました: #{e.message}"
  end

  erb :result
end


########################################
# ChatGPT API を呼び出して情報抽出するためのメソッド
########################################
def call_chatgpt_and_extract_info(text)
  return nil if OPENAI_API_KEY.nil? || OPENAI_API_KEY.strip == ""

  # 現在の日本時間を取得
  now = Time.now.getlocal("+09:00")
  today_date = now.strftime("%Y-%m-%d") # YYYY-MM-DD形式
  current_time = now.strftime("%H:%M:%S") # HH:MM:SS 形式
  client = OpenAI::Client.new(access_token: OPENAI_API_KEY)
  
  # システムに対しては抽出して欲しい形式を明示（JSON 形式など）
  system_content = <<~EOS
    あなたは予定作成アシスタントです。以下のユーザーの自然言語テキストから、予定のタイトル(summary)、開始日時(start_time)、終了日時(end_time)、説明(description)を抽出してください。日本時間（Asia/Tokyo）を想定しています。日付や時刻が指定されていなかった場合、フィールドは空でもかまいません。
    **現在のリクエスト日時は以下の通りです。**
    - 今日の日付: #{today_date}
    - 現在の時刻: #{current_time}
    - 日付が「今日」「明日」「明後日」のように指定されている場合は、上記の日付を基準に計算してください。
    - 「〇時間」や「〇分」などの表記がある場合、開始時間を元に終了時間を計算してください。
    - 終了時間の記載がない場合は、開始時間から1時間後の時間を計算し、終了時間に設定してください。
    形式は必ず JSON で出力してください。例:
    {
      "summary": "会議",
      "start_time": "2025-03-07T10:00:00+09:00",
      "end_time": "2025-03-07T11:00:00+09:00",
      "description": "田中さんとオンラインで"
    }
  EOS

  # ユーザー入力を流し込む
  user_content = text

  # ChatGPT API呼び出し (ChatCompletion)
  response = client.chat(
    parameters: {
      model: "gpt-4o",
      response_format: { type: "json_object" },
      messages: [
        { role: "system", content: system_content },
        { role: "user",   content: user_content }
      ],
      temperature: 0.2,
    }
  )

  content = response.dig("choices", 0, "message", "content")
  p "gptからの返り値"
  p content
  return nil if content.nil?

  begin
    json_data = JSON.parse(content)

    summary = json_data["summary"]
    description = json_data["description"]

    start_time_str = json_data["start_time"]
    end_time_str   = json_data["end_time"]

    start_time = start_time_str && !start_time_str.empty? ? Time.parse(start_time_str) : nil
    end_time   = end_time_str   && !end_time_str.empty?   ? Time.parse(end_time_str)   : nil
    p "start_timeとend_time"
    p start_time
    p end_time
    {
      summary: summary,
      description: description,
      start_time: start_time,
      end_time: end_time
    }
  rescue => e
    p e.message
    return nil
  end
end


# =================================================
# 以下、クライアント生成のためのメソッドたち
# =================================================

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

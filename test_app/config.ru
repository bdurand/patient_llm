  # frozen_string_literal: true

# Load actions
Dir[File.join(__dir__, "actions", "*.rb")].each { |f| require f }

map "/" do
  run IndexAction.new
end

map "/styles.css" do
  run StylesAction.new
end

map "/chat" do
  run ChatAction.new
end

map "/result" do
  run ResultAction.new
end

map "/reset" do
  run ResetAction.new
end

# Sidekiq Web UI
map "/sidekiq" do
  session_secret = File.read(File.join(__dir__, ".session.key")).strip rescue SecureRandom.hex(32)
  use Rack::Session::Cookie, secret: session_secret, same_site: true, max_age: 86400
  run Sidekiq::Web
end

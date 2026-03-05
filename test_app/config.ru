# frozen_string_literal: true

# Load actions
Dir[File.join(__dir__, "actions", "*.rb")].each { |f| require f }

map "/" do
  run IndexAction.new
end

map "/styles.css" do
  run StylesAction.new
end

map "/markdown.js" do
  run ScriptsAction.new("markdown.js")
end

map "/app.js" do
  run ScriptsAction.new("app.js")
end

map "/chat" do
  run ChatAction.new
end

map "/result" do
  run ResultAction.new
end

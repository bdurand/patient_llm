# Sidekiq::AsyncLLM

:construction: NOT RELEASED :construction:

[![Continuous Integration](https://github.com/bdurand/sidekiq-async_llm/actions/workflows/continuous_integration.yml/badge.svg)](https://github.com/bdurand/sidekiq-async_llm/actions/workflows/continuous_integration.yml)
[![Ruby Style Guide](https://img.shields.io/badge/code_style-standard-brightgreen.svg)](https://github.com/testdouble/standard)
[![Gem Version](https://badge.fury.io/rb/sidekiq-async_llm.svg)](https://badge.fury.io/rb/sidekiq-async_llm)

Integrate LLM APIs with your Ruby backend applications without blocking threads. This gem uses asynchronous HTTP requests from within Sidekiq jobs to call LLM providers like OpenAI, Anthropic, and others. When a response is returned, your specified callback worker is invoked to handle the result.

LLM API calls can take a long time to complete. With traditional synchronous HTTP clients, these requests tie up both application threads and Sidekiq worker threads while waiting for responses. This gem solves that problem by using async HTTP, freeing up your threads to do other work while waiting for the LLM provider to respond.

## Usage

### Configuration

You'll also need to configure [RubyLLM](https://github.com/crmne/ruby_llm) with your API keys:

```ruby
RubyLLM.configure do |config|
  config.openai_api_key = ENV["OPENAI_API_KEY"]
  config.anthropic_api_key = ENV["ANTHROPIC_API_KEY"]
  # ... other providers
end
```

You can tune the async HTTP client settings as needed:

```ruby
Sidekiq::AsyncHttp.configure do |config|
  config.max_connections = 1000
end
```

### Creating a Callback Class

Create a callback class with `on_complete` and `on_error` methods:

```ruby
class LLMCallback
  def on_complete(chat, message, callback_args, response)
    # chat          - the Sidekiq::AsyncLLM::Chat instance
    # message       - a RubyLLM::Message with the assistant's response
    # callback_args - a AsyncHttpPool::CallbackArgs containing your custom data
    # response      - the raw AsyncHttpPool::Response with timing info

    # Add the response to the conversation for multi-turn chats
    chat.add_message(message)

    # Access the response content
    puts message.content
    puts "Tokens: #{message.input_tokens} in / #{message.output_tokens} out"
    puts "Duration: #{response.duration}s"

    # Access your custom callback args
    user_id = callback_args[:user_id]

    # Save the chat state for future turns
    save_chat_state(user_id, chat.as_json)
  end

  def on_error(chat, callback_args, error)
    # error - contains error_type, message, and error_class
    # chat  - the Chat instance for context

    log_error(error.error_type, error.message)
  end
end
```

### Making LLM Requests

Create a `Chat` instance and call `ask` to make an async request:

```ruby
chat = Sidekiq::AsyncLLM::Chat.new(callback: LLMCallback)
chat.with_instructions("You are a helpful assistant.")
chat.ask("What is the capital of France?")
```

You can pass custom data to your callback using `callback_args`:

```ruby
chat.ask("Hello!", callback_args: {
  user_id: current_user.id,
  conversation_id: conversation.id
})
```

The request is sent asynchronously. When the LLM responds, your callback's `on_complete` method will be called with the result.

### Chat Configuration Options

The `Chat` class supports various configuration methods:

```ruby
chat = Sidekiq::AsyncLLM::Chat.new(callback: LLMCallback)

# Set the model
chat.with_model("gpt-4o", provider: :openai)

# Set temperature
chat.with_temperature(0.7)

# Enable extended thinking (for supported models)
chat.with_thinking(effort: "high", budget: 10000)

# Set a JSON schema for structured output
chat.with_schema({
  type: "object",
  properties: {
    answer: { type: "string" },
    confidence: { type: "number" }
  }
})

# Add provider-specific parameters
chat.with_params(max_tokens: 1000)

# Add custom HTTP headers
chat.with_headers("X-Custom-Header" => "value")

# Use a custom API base URL (for LM Studio, Ollama, etc.)
chat.with_api_base("http://localhost:1234/v1")
```

### Serializing Conversations

Conversations can be serialized to JSON for storage and later restored:

```ruby
# Initial request
chat = Sidekiq::AsyncLLM::Chat.new(callback: LLMCallback)
chat.with_instructions("You are a helpful assistant.")
chat.ask("Hello!", callback_args: { conversation_id: conversation.id })

# In your callback, save the state:
def on_complete(chat, message, callback_args, response)
  chat.add_message(message)
  save_to_database(callback_args[:conversation_id], chat.as_json)
end

# Later, restore and continue:
chat_data = load_from_database(conversation_id)
chat = Sidekiq::AsyncLLM::Chat.load(chat_data)
chat.ask("Tell me more about that.", callback_args: { conversation_id: conversation_id })
```

## Installation

Add this line to your application's Gemfile:

```ruby
gem "sidekiq-async_llm"
```

Then execute:
```bash
$ bundle
```

Or install it yourself as:
```bash
$ gem install sidekiq-async_llm
```

## Contributing

Open a pull request on [GitHub](https://github.com/bdurand/sidekiq-async_llm).

Please use the [standardrb](https://github.com/testdouble/standard) syntax and lint your code with `standardrb --fix` before submitting.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

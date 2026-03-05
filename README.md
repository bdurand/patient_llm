# PatientHttp::LLM

:construction: NOT RELEASED :construction:

[![Continuous Integration](https://github.com/bdurand/patient_http-llm/actions/workflows/continuous_integration.yml/badge.svg)](https://github.com/bdurand/patient_http-llm/actions/workflows/continuous_integration.yml)
[![Ruby Style Guide](https://img.shields.io/badge/code_style-standard-brightgreen.svg)](https://github.com/testdouble/standard)
[![Gem Version](https://badge.fury.io/rb/patient_http-llm.svg)](https://badge.fury.io/rb/patient_http-llm)

Integrate LLM APIs with your Ruby backend applications without blocking threads. This gem uses asynchronous HTTP requests to call LLM providers like OpenAI, Anthropic, and others. When a response is returned, your specified callback worker is invoked to handle the result.

LLM API calls can take a long time to complete. With traditional synchronous HTTP clients, these requests tie up application threads while waiting for responses. This gem solves that problem by using async HTTP, freeing up your threads to do other work while waiting for the LLM provider to respond.

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

### Creating a Callback Class

Create a callback class with `on_complete` and `on_error` methods:

```ruby
class LLMCallback
  def on_complete(chat, message, callback_args, response)
    # chat          - the PatientHttp::LLM::Chat instance
    # message       - a RubyLLM::Message with the assistant's response
    # callback_args - a PatientHttp::CallbackArgs containing your custom data
    #                 and llm_request_id (the original request id across tool loops)
    # response      - the raw PatientHttp::Response with timing info

    # Add the response to the conversation for multi-turn chats
    chat.add_message(message)

    # Access the response content
    puts message.content
    puts "Tokens: #{message.input_tokens} in / #{message.output_tokens} out"
    puts "Duration: #{response.duration}s"

    # Access your custom callback args
    user_id = callback_args[:user_id]
    request_id = callback_args[:llm_request_id]

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
chat = PatientHttp::LLM::Chat.new(callback: LLMCallback)
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
chat = PatientHttp::LLM::Chat.new(callback: LLMCallback)

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

### Tool Calling

Tools let the LLM invoke your Ruby code during a conversation. When the LLM responds with tool calls, the gem automatically executes them, appends the results, and re-asks the LLM — all asynchronously. The loop continues until the LLM returns a text response.

#### Defining a Tool

Tools are [RubyLLM::Tool](https://github.com/crmne/ruby_llm) subclasses:

```ruby
class WeatherTool < RubyLLM::Tool
  description "Gets the current weather for a city"

  param :city, desc: "City name"

  def execute(city:)
    # Call a weather API, query a database, etc.
    "72°F and sunny in #{city}"
  end
end
```

#### Registering Tools

Register tools on the chat before calling `ask`:

```ruby
chat = PatientHttp::LLM::Chat.new(callback: LLMCallback)
chat.with_tool(WeatherTool)
chat.ask("What's the weather in San Francisco?")
```

You can register multiple tools at once:

```ruby
chat.with_tools(WeatherTool, CalculatorTool, SearchTool)
```

When the LLM responds with tool calls, the gem handles everything automatically:

1. Executes each tool call
2. Appends the results as tool messages
3. Re-asks the LLM asynchronously
4. Repeats until the LLM returns a final text response

Your `on_complete` callback is only invoked once the LLM produces a text response (no more tool calls).

#### Halting the Tool Loop

A tool can stop the loop early by calling `halt`:

```ruby
class SafetyCheckTool < RubyLLM::Tool
  description "Checks if a request is safe to proceed"

  param :request, desc: "The request to check"

  def execute(request:)
    if unsafe?(request)
      halt("I cannot proceed with this request.")
    else
      "Request is safe to proceed."
    end
  end
end
```

When a tool returns `halt(...)`, the loop stops immediately and `on_complete` is called with the halt message.

#### Iteration Limit

To prevent runaway loops, the gem enforces a maximum number of tool iterations (default: 25). If the limit is exceeded, `on_error` is called with a `PatientHttp::LLM::ToolIterationLimitError`.

```ruby
# Customize the limit
chat.with_max_tool_iterations(10)
```

#### Callbacks with Tools

Your callback class works the same whether tools are involved or not. The `on_complete` callback receives the final text response after all tool calls have been resolved:

```ruby
class LLMCallback
  def on_complete(chat, message, callback_args, response)
    # message.content contains the LLM's final text response
    # chat.messages includes the full conversation history
    # (user message, tool calls, tool results, final response, etc.)
    chat.add_message(message)
    save_to_database(callback_args[:conversation_id], chat.as_json)
  end

  def on_error(chat, callback_args, error)
    case error.error_type
    when :tool_iteration_limit
      # Tool loop exceeded max iterations
      log_error("Tool loop limit reached", error.message)
    else
      log_error(error.error_type, error.message)
    end
  end
end
```

### Serializing Conversations

Conversations can be serialized to JSON for storage and later restored:

```ruby
# Initial request
chat = PatientHttp::LLM::Chat.new(callback: LLMCallback)
chat.with_instructions("You are a helpful assistant.")
chat.ask("Hello!", callback_args: { conversation_id: conversation.id })

# In your callback, save the state:
def on_complete(chat, message, callback_args, response)
  chat.add_message(message)
  save_to_database(callback_args[:conversation_id], chat.as_json)
end

# Later, restore and continue:
chat_data = load_from_database(conversation_id)
chat = PatientHttp::LLM::Chat.load(chat_data)
chat.ask("Tell me more about that.", callback_args: { conversation_id: conversation_id })
```

## Installation

Add this line to your application's Gemfile:

```ruby
gem "patient_http-llm"
```

Then execute:
```bash
$ bundle
```

Or install it yourself as:
```bash
$ gem install patient_http-llm
```

## Contributing

Open a pull request on [GitHub](https://github.com/bdurand/patient_http-llm).

Please use the [standardrb](https://github.com/testdouble/standard) syntax and lint your code with `standardrb --fix` before submitting.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

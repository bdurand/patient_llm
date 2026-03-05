# frozen_string_literal: true

class CalculatorTool < RubyLLM::Tool
  description "Perform basic math on two numbers. Supports add, subtract, multiply, and divide."

  param :left, desc: "The left operand (a number)"
  param :operator, desc: "The operator: add, subtract, multiply, or divide"
  param :right, desc: "The right operand (a number)"

  OPERATORS = {
    "add" => :+,
    "subtract" => :-,
    "multiply" => :*,
    "divide" => :/
  }.freeze

  def execute(left:, operator:, right:)
    left = Float(left)
    right = Float(right)
    sym = OPERATORS[operator.to_s.downcase]

    return "Error: unknown operator '#{operator}'. Use add, subtract, multiply, or divide." unless sym
    return "Error: division by zero" if sym == :/ && right.zero?

    result = left.public_send(sym, right)
    "#{left} #{sym} #{right} = #{result}"
  rescue ArgumentError
    "Error: left and right must be valid numbers"
  end
end

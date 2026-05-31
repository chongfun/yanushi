require "dry/monads"
require "dry/struct"

class ServiceResult < Dry::Struct
  extend Dry::Monads[:result]

  attribute? :data, ServiceResultTypes::Any.optional
  attribute? :error, ServiceResultTypes::String.optional
  attribute? :code, ServiceResultTypes::Symbol.optional

  def self.success(data = nil)
    Success(new(data: data, error: nil, code: nil))
  end

  def self.failure(error:, code:, data: nil)
    Failure(new(data: data, error: error.to_s, code: code))
  end
end

module PaymentIngestions
  class UpdateService
    def self.call(user:, ingestion:, params:)
      new(user:, ingestion:, params:).call
    end

    def initialize(user:, ingestion:, params:)
      @user = user
      @ingestion = ingestion
      @params = params
    end

    def call
      return failure("Payment ingestion was not found.", :not_found) unless ingestion.user_id == user.id

      if ingestion.update(params)
        promote_to_matched if promotable_to_matched?
        success(ingestion)
      else
        failure(ingestion.errors.full_messages.to_sentence, :validation_error)
      end
    end

    private

    attr_reader :user, :ingestion, :params

    def promotable_to_matched?
      ingestion.confirmable? && (ingestion.failed? || ingestion.unmatched? || ingestion.ambiguous?)
    end

    def promote_to_matched
      ingestion.update!(status: :matched)
    end

    def success(data)
      ServiceResult.new(success: true, data:, error: nil, code: nil)
    end

    def failure(error, code)
      ServiceResult.new(success: false, data: nil, error:, code:)
    end
  end
end

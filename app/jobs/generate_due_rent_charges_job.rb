class GenerateDueRentChargesJob < ApplicationJob
  queue_as :default

  class GenerationError < StandardError; end

  def perform(as_of = nil)
    through_date = as_of.present? ? as_of.to_date : Date.current
    failures = [] # : Array[String]

    Tenancy.where("commencement_date <= ?", through_date).find_each do |tenancy|
      result = RentCharges::GenerateThroughService.call(tenancy: tenancy, through: through_date)
      if result.failure?
        error_msg = "Tenancy ##{tenancy.id}: [#{result.failure.code}] #{result.failure.error}"
        Rails.logger.error("[GenerateDueRentChargesJob] #{error_msg}")
        failures << error_msg
      end
    end

    if failures.any?
      raise GenerationError, "Failed to generate rent charges for #{failures.size} tenancies:\n#{failures.join("\n")}"
    end
  end
end

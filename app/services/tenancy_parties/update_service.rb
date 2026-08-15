module TenancyParties
  class UpdateService
    ALLOWED_ATTRIBUTES = %i[
      effective_until
    ].freeze

    def self.call(tenancy_party:, attributes: nil, params: nil)
      attrs = (attributes || params || {}).to_h.symbolize_keys
      new(tenancy_party: tenancy_party, attributes: attrs).call
    end

    def initialize(tenancy_party:, attributes:)
      @tenancy_party = tenancy_party
      @attributes = attributes.to_h.symbolize_keys.slice(*ALLOWED_ATTRIBUTES)
    end

    def call
      tenancy = tenancy_party.tenancy

      Tenancy.transaction do
        tenancy.lock!

        updated_attrs = attributes.dup
        if tenancy.termination_date.present? && updated_attrs.key?(:effective_until) && updated_attrs[:effective_until].blank?
          updated_attrs[:effective_until] = tenancy.termination_date
        end

        tenancy_party.assign_attributes(updated_attrs)
        tenancy_party.save!

        unless tenancy.continuous_tenant_coverage?
          tenancy_party.errors.add(:base, "Tenancy must maintain continuous tenant coverage throughout its duration")
          raise ActiveRecord::RecordInvalid, tenancy_party
        end
      end

      ServiceResult.success({ tenancy_party: tenancy_party })
    rescue ActiveRecord::RecordInvalid => e
      failed_record = e.record || tenancy_party
      ServiceResult.failure(
        data: { tenancy_party: tenancy_party },
        error: failed_record.errors.full_messages.to_sentence,
        code: :validation_error
      )
    end

    private

    attr_reader :tenancy_party, :attributes
  end
end

module Tenancies
  class UpdateService
    ALLOWED_ATTRIBUTES = %i[
      termination_date
      agreement_type
      late_period_days
    ].freeze

    def self.call(tenancy:, user: nil, attributes: nil, params: nil)
      attrs = (attributes || params || {}).to_h.symbolize_keys
      new(tenancy: tenancy, attributes: attrs).call
    end

    def initialize(tenancy:, attributes:)
      @tenancy = tenancy
      @attributes = attributes.to_h.symbolize_keys.slice(*ALLOWED_ATTRIBUTES)
    end

    def call
      old_term_date = tenancy.termination_date
      has_new_term_key = attributes.key?(:termination_date)
      new_term_val = attributes[:termination_date]
      new_term_date = if has_new_term_key
        if new_term_val.present?
          if new_term_val.is_a?(String)
            begin
              Date.parse(new_term_val)
            rescue Date::Error, ArgumentError
              tenancy.errors.add(:termination_date, "is invalid")
              return ServiceResult.failure(
                data: { tenancy: tenancy },
                error: "Termination date is invalid",
                code: :validation_error
              )
            end
          else
            new_term_val
          end
        else
          nil
        end
      else
        old_term_date
      end

      if new_term_date
        if tenancy.rent_terms.any? { |rt| rt.effective_from > new_term_date }
          tenancy.errors.add(:termination_date, "cannot precede existing rent terms start date")
          return ServiceResult.failure(
            data: { tenancy: tenancy },
            error: "Cannot set termination date before the start of existing rent term",
            code: :validation_error
          )
        end

        if tenancy.tenancy_parties.any? { |tp| tp.effective_from > new_term_date }
          tenancy.errors.add(:termination_date, "cannot precede existing participants start date")
          return ServiceResult.failure(
            data: { tenancy: tenancy },
            error: "Cannot set termination date before existing participant start date",
            code: :validation_error
          )
        end

        if tenancy.charges.where(charge_kind: "rent").active.where("service_period_end > ?", new_term_date).exists?
          tenancy.errors.add(:termination_date, "cannot precede existing rent charges end date")
          return ServiceResult.failure(
            data: { tenancy: tenancy },
            error: "Cannot set termination date before existing rent charges end date. Void the affected charges first.",
            code: :conflict
          )
        end
      end

      Tenancy.transaction do
        tenancy.rentable_unit.lock!
        tenancy.lock!
        tenancy.assign_attributes(attributes)

        if has_new_term_key
          if old_term_date.present? && new_term_date.present? && new_term_date > old_term_date
            # Tenancy extended: auto-extend child records that ran until the old termination date
            tenancy.rent_terms.lock.where(effective_until: old_term_date).find_each do |rt|
              rt.update!(effective_until: new_term_date)
            end
            tenancy.tenancy_parties.lock.where(effective_until: old_term_date).find_each do |tp|
              tp.update!(effective_until: new_term_date)
            end
          elsif old_term_date.present? && new_term_date.nil?
            # Converted to open-ended: open child records that ran until the old termination date
            tenancy.rent_terms.lock.where(effective_until: old_term_date).find_each do |rt|
              rt.update!(effective_until: nil)
            end
            tenancy.tenancy_parties.lock.where(effective_until: old_term_date).find_each do |tp|
              tp.update!(effective_until: nil)
            end
          elsif new_term_date.present?
            # Tenancy shortened or capped: cap open-ended or exceeding children to new termination date
            tenancy.rent_terms.lock.each do |rt|
              if rt.effective_until.nil? || rt.effective_until > new_term_date
                rt.update!(effective_until: new_term_date)
              end
            end
            tenancy.tenancy_parties.lock.each do |tp|
              if tp.effective_until.nil? || tp.effective_until > new_term_date
                tp.update!(effective_until: new_term_date)
              end
            end
          end
        end

        tenancy.save!

        unless tenancy.continuous_tenant_coverage?
          tenancy.errors.add(:base, "Tenancy must maintain continuous tenant coverage throughout its duration")
          raise ActiveRecord::RecordInvalid, tenancy
        end
      end

      ServiceResult.success({ tenancy: tenancy })
    rescue ActiveRecord::RecordInvalid => e
      failed_record = e.record || tenancy
      ServiceResult.failure(data: { tenancy: tenancy }, error: failed_record.errors.full_messages.to_sentence, code: :validation_error)
    end

    private

    attr_reader :tenancy, :attributes
  end
end

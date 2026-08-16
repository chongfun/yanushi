module Accounting
  class PostingBuilder
    def self.call(user:, postings:)
      new(user: user, postings: postings).call
    end

    def initialize(user:, postings:)
      @user = user
      @postings = Array(postings)
    end

    def call
      if postings.length < 2
        return ServiceResult.failure(
          error: "A journal entry must have at least two postings",
          code: :invalid_postings
        )
      end

      total_sum = 0
      normalized_postings = [] # : Array[Hash[Symbol, untyped]]
      user_accounts = user.accounts.reload.index_by(&:key)

      postings.each do |p|
        cents = p.amount_cents
        unless cents.is_a?(Integer) && cents != 0
          return ServiceResult.failure(
            error: "Posting amount must be a non-zero integer in cents",
            code: :invalid_postings
          )
        end

        total_sum += cents

        account = user_accounts[p.account_key]
        unless account
          return ServiceResult.failure(
            error: "Account '#{p.account_key}' not found for user",
            code: :missing_account
          )
        end

        unless account.active?
          return ServiceResult.failure(
            error: "Account '#{p.account_key}' is inactive",
            code: :inactive_account
          )
        end

        # Dimension persistence validation
        [ p.property, p.rentable_unit, p.tenancy, p.party ].each do |dim|
          next unless dim

          unless dim.is_a?(ActiveRecord::Base) && dim.persisted? && !dim.destroyed?
            return ServiceResult.failure(
              error: "Dimension must be a persisted record",
              code: :invalid_dimension
            )
          end
        end

        # Ownership validation
        if p.property && p.property.user_id != user.id
          return ServiceResult.failure(
            error: "Property does not belong to user",
            code: :ownership_mismatch
          )
        end

        if p.rentable_unit && p.rentable_unit.property&.user_id != user.id
          return ServiceResult.failure(
            error: "Rentable unit does not belong to user",
            code: :ownership_mismatch
          )
        end

        if p.tenancy && p.tenancy.rentable_unit&.property&.user_id != user.id
          return ServiceResult.failure(
            error: "Tenancy does not belong to user",
            code: :ownership_mismatch
          )
        end

        if p.party && p.party.user_id != user.id
          return ServiceResult.failure(
            error: "Party does not belong to user",
            code: :ownership_mismatch
          )
        end

        # Dimension derivation & contradiction check
        resolved_property = p.property
        resolved_unit = p.rentable_unit
        resolved_tenancy = p.tenancy

        if resolved_tenancy
          expected_unit = resolved_tenancy.rentable_unit
          unless expected_unit&.persisted? && !expected_unit.destroyed?
            return ServiceResult.failure(
              error: "Dimension must be a persisted record",
              code: :invalid_dimension
            )
          end

          if resolved_unit && resolved_unit.id != expected_unit.id
            return ServiceResult.failure(
              error: "Contradictory dimensions: tenancy does not belong to specified rentable unit",
              code: :dimension_mismatch
            )
          end
          resolved_unit = expected_unit

          expected_prop = expected_unit.property
          unless expected_prop&.persisted? && !expected_prop.destroyed?
            return ServiceResult.failure(
              error: "Dimension must be a persisted record",
              code: :invalid_dimension
            )
          end

          if resolved_property && resolved_property.id != expected_prop.id
            return ServiceResult.failure(
              error: "Contradictory dimensions: tenancy does not belong to specified property",
              code: :dimension_mismatch
            )
          end
          resolved_property = expected_prop
        elsif resolved_unit
          expected_prop = resolved_unit.property
          unless expected_prop&.persisted? && !expected_prop.destroyed?
            return ServiceResult.failure(
              error: "Dimension must be a persisted record",
              code: :invalid_dimension
            )
          end

          if resolved_property && resolved_property.id != expected_prop.id
            return ServiceResult.failure(
              error: "Contradictory dimensions: rentable unit does not belong to specified property",
              code: :dimension_mismatch
            )
          end
          resolved_property = expected_prop
        end

        normalized_postings << {
          account: account,
          account_id: account.id,
          amount_cents: cents,
          property_id: resolved_property&.id,
          rentable_unit_id: resolved_unit&.id,
          tenancy_id: resolved_tenancy&.id,
          party_id: p.party&.id,
          memo: p.memo
        }
      end

      if total_sum != 0
        return ServiceResult.failure(
          error: "Journal entry is unbalanced: net sum is #{total_sum}",
          code: :unbalanced_entry
        )
      end

      ServiceResult.success(postings: normalized_postings)
    end

    private

      attr_reader :user, :postings
  end
end

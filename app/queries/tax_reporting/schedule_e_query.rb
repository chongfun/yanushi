module TaxReporting
  class ScheduleEQuery
    def self.call(property:, tax_year: nil)
      new(property: property, tax_year: tax_year).call
    end

    def initialize(property:, tax_year: nil)
      @property = property
      @tax_year_obj = if tax_year.nil?
        TaxYear.new(Date.current.year)
      else
        TaxYear.parse(tax_year) || raise(ArgumentError, "Invalid tax year #{tax_year.inspect}; must be between #{TaxYear::MIN_YEAR} and #{TaxYear::MAX_YEAR}")
      end
      @tax_year = @tax_year_obj.to_i
    end

    def call
      return empty_result unless property

      tax_profile = property.tax_profile_for(tax_year)
      status = tax_profile ? :ok : :tax_profile_required

      resolutions = load_resolutions
      period_postings = load_period_postings

      rents_received_cents, rents_drilldown = calculate_rents_received(period_postings, resolutions)
      expenses_by_category, total_expenses_cents, other_details, expense_drilldown, unmapped_reviews = calculate_expenses(period_postings, resolutions)
      review_items = collect_review_items(period_postings, unmapped_reviews, resolutions)

      net_income_cents = rents_received_cents - total_expenses_cents

      ScheduleEResult.new(
        property: property,
        tax_year: tax_year,
        tax_profile: tax_profile,
        status: status,
        rents_received_cents: rents_received_cents,
        expenses_by_category_cents: expenses_by_category,
        total_expenses_cents: total_expenses_cents,
        net_income_cents: net_income_cents,
        other_expense_details: other_details,
        review_items: review_items,
        rents_received_drilldown: rents_drilldown,
        expense_drilldown_by_category: expense_drilldown
      )
    end

    private

      attr_reader :property, :tax_year

      def load_resolutions
        prop = property
        return {} unless prop

        prop.tax_review_resolutions.reload.index_by(&:journal_entry_id)
      end

      def start_date
        Date.new(tax_year, 1, 1)
      end

      def end_date
        Date.new(tax_year, 12, 31)
      end

      def load_period_postings
        prop = property
        return Posting.none unless prop

        prop.postings
            .joins(:journal_entry)
            .where(journal_entries: { occurred_on: start_date..end_date })
            .includes(:account, :party, :rentable_unit, :tenancy, journal_entry: [ :source, :reversal, reversal_of: [ :source, :reversal, postings: :account ] ])
            .order("journal_entries.occurred_on ASC, journal_entries.id ASC, postings.id ASC")
      end

      def calculate_rents_received(postings, resolutions = {})
        rents_cents = 0
        drilldown = [] # : Array[ScheduleEResult::IncomeDrilldownItem]

        cash_postings = postings.select { |p| p.account&.key == "cash" }

        cash_postings.each do |posting|
          entry = posting.journal_entry
          classification = ScheduleEEventMap.classify_income_event(entry)

          case classification
          when :rents_received
            rents_cents += posting.amount_cents.to_i
            drilldown << ScheduleEResult::IncomeDrilldownItem.new(
              id: entry.id,
              occurred_on: entry.occurred_on,
              label: "Payment received",
              description: entry.description,
              amount_cents: posting.amount_cents.to_i,
              party: posting.party,
              journal_entry: entry,
              reversal: false
            )
          when :rents_received_reversal
            rents_cents += posting.amount_cents.to_i # posting.amount_cents is negative for cash reversal
            drilldown << ScheduleEResult::IncomeDrilldownItem.new(
              id: entry.id,
              occurred_on: entry.occurred_on,
              label: "Payment reversal",
              description: entry.description,
              amount_cents: posting.amount_cents.to_i,
              party: posting.party,
              journal_entry: entry,
              reversal: true
            )
          end
        end

        # Group postings by journal entry so derivation is deterministic
        entries_by_id = postings.group_by(&:journal_entry_id)

        entries_by_id.each do |entry_id, entry_postings|
          entry = entry_postings.first.journal_entry
          classification = ScheduleEEventMap.classify_income_event(entry)

          case classification
          when :review_required
            resolution = resolutions[entry.id]
            next unless resolution&.include_in_rents?

            amount = extract_review_item_amount(entry, entry_postings)
            next if amount.zero?

            rents_cents += amount
            label = if entry.event_type == "deposit_applied"
              "Security deposit applied (included in rents)"
            else
              "Tax review item (included in rents)"
            end

            party_record = entry_postings.map(&:party).compact.first || entry_postings.map(&:tenancy).compact.first&.parties&.first

            drilldown << ScheduleEResult::IncomeDrilldownItem.new(
              id: entry.id,
              occurred_on: entry.occurred_on,
              label: label,
              description: entry.description,
              amount_cents: amount,
              party: party_record,
              journal_entry: entry,
              reversal: false
            )
          when :reversal_of_reviewed
            orig = entry.reversal_of
            next unless orig

            orig_resolution = resolutions[orig.id]
            next unless orig_resolution&.include_in_rents?

            amount = extract_review_item_amount(entry, entry_postings)
            next if amount.zero?

            effective_amount = -amount
            rents_cents += effective_amount
            label = if orig.event_type == "deposit_applied"
              "Deposit application reversal (included in rents)"
            else
              "Tax review item reversal (included in rents)"
            end

            party_record = entry_postings.map(&:party).compact.first || entry_postings.map(&:tenancy).compact.first&.parties&.first

            drilldown << ScheduleEResult::IncomeDrilldownItem.new(
              id: entry.id,
              occurred_on: entry.occurred_on,
              label: label,
              description: entry.description,
              amount_cents: effective_amount,
              party: party_record,
              journal_entry: entry,
              reversal: true
            )
          end
        end

        [ rents_cents, drilldown ]
      end

      def extract_review_item_amount(entry, entry_postings)
        if entry.event_type == "deposit_applied" || (entry.reversal? && entry.reversal_of&.event_type == "deposit_applied")
          dep_posting = entry_postings.find { |p| p.account&.key == "tenant_receivable" || p.account&.key == "security_deposits_held" }
          dep_posting&.amount_cents&.to_i&.abs || 0
        else
          c_postings = entry_postings.select { |p| p.account&.key == "cash" }
          if entry.reversal? || entry.event_type == "reversal"
            c_postings.select { |p| p.amount_cents.to_i.negative? }.sum { |p| p.amount_cents.to_i.abs }
          else
            c_postings.select { |p| p.amount_cents.to_i.positive? }.sum { |p| p.amount_cents.to_i }
          end
        end
      end

      def calculate_expenses(postings, resolutions = {})
        categories = {} # : Hash[Symbol, Integer]
        ScheduleEAccountMap.supported_categories.each { |cat| categories[cat] = 0 }
        other_details = [] # : Array[ScheduleEResult::OtherExpenseDetail]
        drilldown = Hash.new { |h, k| h[k] = [] }
        unmapped_reviews = [] # : Array[ScheduleEResult::TaxReviewItem]

        prop_id = property&.id
        return [ categories, 0, other_details, drilldown, unmapped_reviews ] unless prop_id

        expense_postings = postings.select { |p| p.account&.account_type == "expense" }

        expense_postings.each do |posting|
          entry = posting.journal_entry
          classification = ScheduleEEventMap.classify_income_event(entry)
          is_reversal = entry.reversal? || entry.event_type == "reversal"
          orig = entry.reversal_of

          target_entry = (is_reversal && orig) ? orig : entry
          target_postings = target_entry.postings.select do |p|
            p.property_id == prop_id ||
              p.rentable_unit&.property_id == prop_id ||
              p.tenancy&.rentable_unit&.property_id == prop_id
          end
          unmapped_acct_ids = target_postings
            .select { |p| p.account&.account_type == "expense" && ScheduleEAccountMap.category_for(p.account&.key).nil? }
            .map(&:account_id)
            .compact
            .uniq
          has_multiple_unmapped = unmapped_acct_ids.size > 1

          category = if is_reversal && orig
            orig_resolution = resolutions[orig.id]
            orig_classification = ScheduleEEventMap.classify_income_event(orig)

            if orig_classification == :review_required
              if !has_multiple_unmapped && orig_resolution&.map_to_schedule_e_category? && (cat_str = orig_resolution.schedule_e_category)
                cat_str.to_sym
              else
                nil
              end
            else
              mapped_cat = ScheduleEAccountMap.category_for(posting.account&.key)
              if mapped_cat
                mapped_cat
              else
                account_name = posting.account&.name || "Unknown"
                if has_multiple_unmapped
                  unmapped_reviews << ScheduleEResult::TaxReviewItem.new(
                    id: entry.id,
                    occurred_on: entry.occurred_on,
                    amount_cents: posting.amount_cents.to_i.abs,
                    reason: "Reversal of entry containing multiple unmapped expense accounts ('#{account_name}'); requires individual account resolution",
                    source: entry.source,
                    journal_entry: entry,
                    resolution: nil,
                    review_kind: :expense
                  )
                  nil
                else
                  if orig.occurred_on.year != tax_year && orig_resolution.present?
                    unmapped_reviews << ScheduleEResult::TaxReviewItem.new(
                      id: entry.id,
                      occurred_on: entry.occurred_on,
                      amount_cents: posting.amount_cents.to_i.abs,
                      reason: "Reversal of #{orig.occurred_on.year} unmapped expense '#{account_name}'; tax treatment derived from original event",
                      source: entry.source,
                      journal_entry: entry,
                      resolution: orig_resolution,
                      review_kind: :expense
                    )
                  end

                  if orig_resolution&.map_to_schedule_e_category? && (cat_str = orig_resolution.schedule_e_category)
                    cat_str.to_sym
                  elsif orig_resolution&.exclude? || orig_resolution&.include_in_rents?
                    nil
                  else
                    unmapped_reviews << ScheduleEResult::TaxReviewItem.new(
                      id: entry.id,
                      occurred_on: entry.occurred_on,
                      amount_cents: posting.amount_cents.to_i.abs,
                      reason: "Reversal of unmapped expense account '#{account_name}'",
                      source: entry.source,
                      journal_entry: entry,
                      resolution: orig_resolution,
                      review_kind: :expense
                    )
                    nil
                  end
                end
              end
            end
          elsif classification == :review_required
            resolution = resolutions[entry.id]
            if !has_multiple_unmapped && resolution&.map_to_schedule_e_category? && (cat_str = resolution.schedule_e_category)
              cat_str.to_sym
            else
              nil
            end
          else
            mapped_cat = ScheduleEAccountMap.category_for(posting.account&.key)
            unless mapped_cat
              account_name = posting.account&.name || "Unknown"
              if has_multiple_unmapped
                unmapped_reviews << ScheduleEResult::TaxReviewItem.new(
                  id: entry.id,
                  occurred_on: entry.occurred_on,
                  amount_cents: posting.amount_cents.to_i.abs,
                  reason: "Entry contains multiple unmapped expense accounts ('#{account_name}'); requires individual account resolution",
                  source: entry.source,
                  journal_entry: entry,
                  resolution: nil,
                  review_kind: :expense
                )
                mapped_cat = nil
              else
                resolution = resolutions[entry.id]
                unmapped_reviews << ScheduleEResult::TaxReviewItem.new(
                  id: entry.id,
                  occurred_on: entry.occurred_on,
                  amount_cents: posting.amount_cents.to_i.abs,
                  reason: "Unmapped expense account '#{account_name}'; no Schedule E category",
                  source: entry.source,
                  journal_entry: entry,
                  resolution: resolution,
                  review_kind: :expense
                )

                if resolution&.map_to_schedule_e_category? && (cat_str = resolution.schedule_e_category)
                  mapped_cat = cat_str.to_sym
                end
              end
            end
            mapped_cat
          end

          next unless category

          current_val = categories[category] || 0
          categories[category] = (current_val + posting.amount_cents.to_i).to_i

          item_desc = entry.source.respond_to?(:description) ? entry.source.description.presence : nil
          item_desc ||= entry.description

          drilldown[category] << ScheduleEResult::ExpenseDrilldownItem.new(
            id: entry.id,
            occurred_on: entry.occurred_on,
            category: category,
            description: item_desc,
            amount_cents: posting.amount_cents.to_i,
            property: posting.property,
            rentable_unit: posting.rentable_unit,
            journal_entry: entry,
            reversal: is_reversal
          )

          if category == :other
            other_details << ScheduleEResult::OtherExpenseDetail.new(
              id: entry.id,
              occurred_on: entry.occurred_on,
              description: item_desc,
              amount_cents: posting.amount_cents.to_i,
              journal_entry: entry
            )
          end
        end

        total_cents = categories.values.sum

        [ categories, total_cents, other_details, drilldown, unmapped_reviews ]
      end

      def collect_review_items(postings, unmapped_reviews = [], resolutions = {})
        items = Array.new(unmapped_reviews) # : Array[ScheduleEResult::TaxReviewItem]
        seen_entry_ids = Set.new(unmapped_reviews.map(&:id))

        postings.each do |posting|
          entry = posting.journal_entry
          next if seen_entry_ids.include?(entry.id)

          seen_entry_ids << entry.id

          classification = ScheduleEEventMap.classify_income_event(entry)
          orig = entry.reversal_of

          if classification == :reversal_of_reviewed
            if orig && orig.occurred_on.year != tax_year
              orig_resolution = resolutions[orig.id]
              reason_text = if orig_resolution.nil?
                "Reversal of unresolved #{orig.occurred_on.year} event (#{orig.event_type}); resolve original event to determine tax treatment"
              else
                "Reversal of #{orig.occurred_on.year} event (#{orig.event_type}); tax treatment derived from original event"
              end

              items << ScheduleEResult::TaxReviewItem.new(
                id: entry.id,
                occurred_on: entry.occurred_on,
                amount_cents: posting.amount_cents.to_i.abs,
                reason: reason_text,
                source: entry.source,
                journal_entry: entry,
                resolution: orig_resolution,
                review_kind: :income
              )
            end
          elsif classification == :review_required
            reason_text = if entry.event_type == "deposit_applied"
              "Security deposit applied to charge; review tax treatment"
            elsif entry.source_type != "Receipt" && entry.event_type == "receipt_posted"
              "Unrecognized source type '#{entry.source_type}' for receipt event; review tax treatment"
            else
              "Unrecognized financial event '#{entry.event_type}'; review tax treatment"
            end

            entry_postings = postings.select { |p| p.journal_entry_id == entry.id }
            entry_amount_cents = if entry.event_type == "deposit_applied"
              dep_posting = entry_postings.find { |p| p.account&.key == "tenant_receivable" || p.account&.key == "security_deposits_held" }
              dep_posting&.amount_cents&.to_i&.abs || posting.amount_cents.to_i.abs
            else
              cash_p = entry_postings.select { |p| p.account&.key == "cash" && p.amount_cents.positive? }
              if cash_p.any?
                cash_p.sum(&:amount_cents)
              else
                entry_postings.map(&:amount_cents).map(&:abs).max || posting.amount_cents.to_i.abs
              end
            end

            has_expense = entry_postings.any? { |p| p.account&.account_type == "expense" }
            has_cash_inflow = entry_postings.any? { |p| p.account&.key == "cash" && p.amount_cents.positive? }
            is_deposit = entry.event_type == "deposit_applied"

            r_kind = if has_expense && !has_cash_inflow && !is_deposit
              :expense
            else
              :income
            end

            items << ScheduleEResult::TaxReviewItem.new(
              id: entry.id,
              occurred_on: entry.occurred_on,
              amount_cents: entry_amount_cents,
              reason: reason_text,
              source: entry.source,
              journal_entry: entry,
              resolution: resolutions[entry.id],
              review_kind: r_kind
            )
          end
        end

        items
      end

      def empty_result
        ScheduleEResult.new(
          property: property,
          tax_year: tax_year,
          tax_profile: nil,
          status: :tax_profile_required,
          rents_received_cents: 0,
          expenses_by_category_cents: {},
          total_expenses_cents: 0,
          net_income_cents: 0,
          other_expense_details: [],
          review_items: [],
          rents_received_drilldown: [],
          expense_drilldown_by_category: {}
        )
      end
  end
end

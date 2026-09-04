module Dashboards
  class AttentionQuery
    class AttentionItem < Data.define(:kind, :title, :description, :path, :severity)
    end

    def self.call(user:, tenancies: nil, balances: nil)
      new(user: user, tenancies: tenancies, balances: balances).call
    end

    def initialize(user:, tenancies: nil, balances: nil)
      @user = user
      @tenancies = tenancies
      @balances = balances
    end

    def call
      return [] unless user

      items = [] # : Array[AttentionItem]
      items.concat(inbox_review_items)
      items.concat(import_failed_items)
      items.concat(overdue_balance_items)
      items.concat(schedule_e_items)
      items
    end

    private

      attr_reader :user, :tenancies, :balances

      def inbox_review_items
        u = user
        return [] unless u

        reviewable_scope = u.imported_transactions.reviewable
        count = reviewable_scope.count
        return [] if count.zero?

        newest = reviewable_scope.order(occurred_on: :desc, id: :desc).first
        description = if newest
          parts = [] # : Array[String]
          if newest.amount_cents
            parts << "Most recent: #{FormattingHelper.format_money_cents(newest.amount_cents)}"
          end
          payer = newest.payer_name.presence || newest.payer_username.presence
          parts << "from #{payer}" if payer
          parts << newest.occurred_on.strftime("%b %-d") if newest.occurred_on
          parts.join(", ")
        else
          "Imported transactions awaiting review"
        end

        title = count == 1 ? "1 imported transaction needs review" : "#{count} imported transactions need review"

        [
          AttentionItem.new(
            kind: :inbox_review,
            title: title,
            description: description,
            path: Rails.application.routes.url_helpers.inbox_path,
            severity: :warn
          )
        ]
      end

      def import_failed_items
        u = user
        return [] unless u

        failed_docs = u.source_documents.failed.order(created_at: :desc)
        failed_docs.map do |doc|
          msg = doc.error_message.presence || "Processing failed"
          AttentionItem.new(
            kind: :import_failed,
            title: "A statement upload failed to process",
            description: "#{doc.attachment_filename} · #{msg}",
            path: Rails.application.routes.url_helpers.inbox_path(view: "processing"),
            severity: :danger
          )
        end
      end

      # Only money that is actually late belongs here. A positive balance on its
      # own is normal for the days between a rent charge posting and the payment
      # clearing; surfacing it would fill this list every month and teach the
      # owner to ignore it. The portfolio summary still counts every balance.
      def overdue_balance_items
        u = user
        return [] unless u

        user_tenancies = tenancies || Tenancy.joins(rentable_unit: :property)
                                             .where(properties: { user_id: u.id })
                                             .includes({ tenancy_parties: :party }, rentable_unit: :property)

        return [] if user_tenancies.empty?

        effective_balances = balances || Accounting::TenancyBalancesQuery.call(tenancies: user_tenancies)
        overdue_by_tenancy = Tenancies::OverdueQuery.call(
          tenancies: user_tenancies,
          balances: effective_balances
        )

        user_tenancies.filter_map do |tenancy|
          balance_cents = effective_balances[tenancy.id] || 0
          overdue_cents = overdue_by_tenancy[tenancy.id] || 0
          next unless overdue_cents.positive?

          as_of_date = if tenancy.active?
            Date.current
          elsif tenancy.upcoming?
            tenancy.commencement_date || Date.current
          else
            tenancy.termination_date || tenancy.commencement_date || Date.current
          end

          active_tenants = tenancy.tenant_parties_as_of(as_of_date)
          tenant_parties = active_tenants.presence || tenancy.all_tenant_parties
          party_names = tenant_parties.map(&:display_name).compact.presence
          tenant_label = party_names ? party_names.to_sentence : "Tenant"
          property_name = tenancy.rentable_unit&.property&.address || "Property"
          unit_name = tenancy.rentable_unit&.name || "Unit"

          parts = [ property_name, unit_name ] # : Array[String]
          if tenancy.upcoming?
            parts << "Upcoming tenancy"
          elsif !tenancy.active?
            parts << "Past tenancy"
          end
          not_yet_due_cents = balance_cents - overdue_cents
          if not_yet_due_cents.positive?
            parts << "#{FormattingHelper.format_money_cents(not_yet_due_cents)} more not yet due"
          end

          AttentionItem.new(
            kind: :balance_due,
            title: "#{tenant_label} is #{FormattingHelper.format_money_cents(overdue_cents)} overdue",
            description: parts.join(" · "),
            path: Rails.application.routes.url_helpers.tenancy_path(tenancy),
            severity: :warn
          )
        end
      end

      # PRD 8.2: unresolved Schedule E work, as one aggregate item so the queue
      # stays readable. The year that matters is the one being filed: the most
      # recent year with ledger activity that is already over.
      def schedule_e_items
        u = user
        return [] unless u

        year = filing_tax_year(u)
        return [] unless year

        summary = schedule_e_summary(u, year)
        property_count = summary[:property_count].to_i
        return [] if property_count.zero?

        title = if property_count == 1
          "1 property is not ready for Schedule E"
        else
          "#{property_count} properties are not ready for Schedule E"
        end

        parts = [ "#{year} tax year" ] # : Array[String]
        profile_count = summary[:profile_count].to_i
        if profile_count.positive?
          parts << (profile_count == 1 ? "1 property needs a tax profile" : "#{profile_count} properties need a tax profile")
        end
        review_count = summary[:review_count].to_i
        if review_count.positive?
          parts << (review_count == 1 ? "1 item needs review" : "#{review_count} items need review")
        end

        [
          AttentionItem.new(
            kind: :schedule_e_review,
            title: title,
            description: parts.join(" · "),
            path: Rails.application.routes.url_helpers.reports_path(year: year),
            severity: :warn
          )
        ]
      end

      # Three counts is all the item says, but reaching them runs the whole
      # Schedule E computation once per property, which is too much for the
      # app's front door: a twenty-property portfolio measured about twelve
      # queries per property. The answer changes only when a posting, a
      # resolution, or a tax profile changes, so the key covers all three and a
      # stale item cannot outlive the data it describes. The hour bounds the one
      # input the key cannot see, a change to the account map in code.
      #
      # The proper fix is a status query that does not scale with the portfolio;
      # this keeps the dashboard cheap until that lands.
      def schedule_e_summary(u, year)
        Rails.cache.fetch(schedule_e_cache_key(u, year), expires_in: 1.hour) do
          needs_work = Reports::ScheduleEStatusesQuery.call(user: u, tax_year: year).select(&:needs_work?)

          {
            property_count: needs_work.size,
            profile_count: needs_work.count { |status| status.state == :needs_profile },
            review_count: needs_work.sum { |status| status.unresolved_review_count }
          }
        end
      end

      def schedule_e_cache_key(u, year)
        property_ids = u.properties.select(:id)

        [
          "dashboards/schedule_e_attention",
          u.id,
          year,
          u.properties.count,
          u.journal_entries.maximum(:posted_at)&.to_i,
          PropertyTaxReviewResolution.where(property_id: property_ids).maximum(:updated_at)&.to_i,
          PropertyTaxProfile.where(property_id: property_ids).maximum(:updated_at)&.to_i
        ]
      end

      # The most recent year with ledger activity that is earlier than this one.
      # Accounting::ActiveYearsQuery always includes the current year, so the
      # filter is what makes this "a year the owner would be filing".
      def filing_tax_year(u)
        Accounting::ActiveYearsQuery.call(user: u).select { |year| year < Date.current.year }.max
      end
  end
end

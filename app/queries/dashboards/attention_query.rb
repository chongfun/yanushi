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
      items.concat(balance_due_items)
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

      def balance_due_items
        u = user
        return [] unless u

        user_tenancies = tenancies || Tenancy.joins(rentable_unit: :property)
                                             .where(properties: { user_id: u.id })
                                             .includes({ tenancy_parties: :party }, rentable_unit: :property)

        return [] if user_tenancies.empty?

        effective_balances = balances || Accounting::TenancyBalancesQuery.call(tenancies: user_tenancies)

        user_tenancies.filter_map do |tenancy|
          balance_cents = effective_balances[tenancy.id] || 0
          next unless balance_cents.positive?

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
          desc_suffix = if tenancy.active?
            "balance outstanding"
          elsif tenancy.upcoming?
            "Upcoming tenancy · balance outstanding"
          else
            "Past tenancy · balance outstanding"
          end

          AttentionItem.new(
            kind: :balance_due,
            title: "#{tenant_label} owes #{FormattingHelper.format_money_cents(balance_cents)}",
            description: "#{property_name} · #{unit_name} · #{desc_suffix}",
            path: Rails.application.routes.url_helpers.tenancy_path(tenancy),
            severity: :warn
          )
        end
      end
  end
end

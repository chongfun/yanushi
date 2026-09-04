require "csv"

module Tenancies
  # The same statement as a spreadsheet, which is usually what an accountant
  # actually asks for.
  #
  # Shape: a short preamble naming the tenancy, the period, and the balances,
  # a blank line, then the rows. Money keeps the app's formatting so the sheet
  # reads like the page and the PDF; a `Status` column carries the audit state
  # as one filterable word, because a voided row that looks like any other row
  # is worse than no export at all.
  class StatementCsvService
    ACCOUNT_COLUMNS = [ "Date", "Activity", "Notes", "Status", "Amount", "Running balance" ].freeze
    ACTIVITY_COLUMNS = [ "Date", "Event", "Participant", "Status", "Amount" ].freeze

    def self.call(tenancy:, date_range:, statement: nil, activity_rows: nil)
      new(
        tenancy: tenancy,
        date_range: date_range,
        statement: statement,
        activity_rows: activity_rows
      ).call
    end

    def initialize(tenancy:, date_range:, statement: nil, activity_rows: nil)
      @tenancy = tenancy
      @date_range = date_range
      @statement = statement
      @activity_rows = activity_rows || []
    end

    def call
      CSV.generate do |csv|
        write_preamble(csv)
        csv << []

        result = statement
        if result
          write_account_rows(csv, result.rows)
        else
          write_activity_rows(csv, activity_rows)
        end
      end
    end

    private

      attr_reader :tenancy, :date_range, :statement, :activity_rows

      def view_mode
        statement ? "receivable" : "all"
      end

      def write_preamble(csv)
        csv << [ StatementExport.title(view_mode) ]
        StatementExport.identity_lines(tenancy).each { |label, value| csv << [ label, value ] }
        csv << [ "Period", StatementExport.period_label(date_range) ]

        result = statement
        if result
          csv << [ "Opening balance", StatementExport.signed_money(result.opening_balance_cents) ]
          csv << [ "Closing balance", StatementExport.signed_money(result.closing_balance_cents) ]
        end

        csv << [ "Generated", StatementExport.iso_date(Date.current) ]
        csv << [ "Note", StatementExport::AUDIT_NOTE ]
      end

      def write_account_rows(csv, rows)
        csv << ACCOUNT_COLUMNS.dup

        rows.each do |row|
          csv << [
            StatementExport.iso_date(row.occurred_on),
            StatementExport.activity_label(row),
            StatementExport.statement_notes(row),
            StatementExport.status_word(row),
            StatementExport.signed_money(row.amount_cents),
            StatementExport.signed_money(row.running_balance_cents)
          ]
        end
      end

      def write_activity_rows(csv, rows)
        csv << ACTIVITY_COLUMNS.dup

        rows.each do |row|
          csv << [
            StatementExport.iso_date(row.occurred_on),
            StatementExport.event_label(row),
            StatementExport.party_name(row),
            StatementExport.status_word(row),
            StatementExport.signed_money(row.amount_cents)
          ]
        end
      end
  end
end

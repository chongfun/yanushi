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

    # A spreadsheet reads a cell beginning with one of these as a formula, so a
    # tenant name, an address, or a memo could execute when the accountant
    # opens the file. Quoting the CSV field does not help: the danger is in how
    # Excel and LibreOffice interpret the value afterwards.
    FORMULA_TRIGGERS = [ "=", "+", "-", "@", "\t", "\r", "\n" ].freeze

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
        StatementExport.identity_lines(tenancy).each { |label, value| csv << [ label, csv_text(value) ] }
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
            csv_text(StatementExport.activity_label(row)),
            csv_text(StatementExport.statement_notes(row)),
            StatementExport.status_word(row),
            StatementExport.signed_money(row.amount_cents),
            StatementExport.signed_money(row.running_balance_cents)
          ]
        end
      end

      # Neutralizes a formula-triggering cell by making it literal text, which
      # Excel and LibreOffice both honor and neither displays. Only cells whose
      # content originates with a person go through here: the money columns are
      # written by this service and legitimately begin with a minus sign, which
      # a spreadsheet reads as a negative number rather than a formula.
      def csv_text(value)
        string = value.to_s
        return string unless string.start_with?(*FORMULA_TRIGGERS)

        "'#{string}"
      end

      def write_activity_rows(csv, rows)
        csv << ACTIVITY_COLUMNS.dup

        rows.each do |row|
          csv << [
            StatementExport.iso_date(row.occurred_on),
            csv_text(StatementExport.event_label(row)),
            csv_text(StatementExport.party_name(row)),
            StatementExport.status_word(row),
            StatementExport.signed_money(row.amount_cents)
          ]
        end
      end
  end
end

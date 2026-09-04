module Tenancies
  # The tenant account statement as a document that can leave the app: the one
  # thing a landlord mails a tenant or hands an accountant.
  #
  # It covers the same rows the HTML page shows for the same filter, in both of
  # the page's views: the tenant receivable account (opening balance, rows with
  # a running balance, closing balance) and the full financial activity log.
  # Pass `statement:` for the account view, `activity_rows:` for the log.
  class StatementPdfService
    PAGE_MARGIN = 48
    INK = "1C1917".freeze         # stone-900
    MUTED = "78716C".freeze       # stone-500
    FAINT = "A8A29E".freeze       # stone-400
    HAIRLINE = "E7E5E4".freeze    # stone-200
    NO_BORDERS = [] # : Array[Symbol]
    ROW_BORDERS = [ :bottom ].freeze

    ACCOUNT_COLUMNS = [ "Date", "Activity", "Notes", "Amount", "Balance" ].freeze
    ACCOUNT_WIDTHS = { 0 => 74, 1 => 190, 2 => 82, 3 => 74, 4 => 96 }.freeze
    ACTIVITY_COLUMNS = [ "Date", "Event", "Participant", "Notes", "Amount" ].freeze
    ACTIVITY_WIDTHS = { 0 => 74, 1 => 176, 2 => 110, 3 => 76, 4 => 80 }.freeze

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
      pdf = Prawn::Document.new({ page_size: "LETTER", margin: PAGE_MARGIN })
      draw_masthead(pdf)

      result = statement
      if result
        draw_balances(pdf, result)
        draw_account_rows(pdf, result.rows)
      else
        draw_activity_rows(pdf, activity_rows)
      end

      draw_footnotes(pdf)
      draw_page_numbers(pdf)
      pdf.render
    end

    private

      attr_reader :tenancy, :date_range, :statement, :activity_rows

      def view_mode
        statement ? "receivable" : "all"
      end

      # Who and what the document is about, then the period it covers.
      def draw_masthead(pdf)
        pdf.text StatementExport.title(view_mode), size: 17, style: :bold, color: INK
        pdf.move_down 8
        pdf.text StatementExport.tenant_names(tenancy), size: 11, color: INK
        pdf.move_down 3
        pdf.text subject_line, size: 9, color: MUTED
        pdf.move_down 3
        pdf.text StatementExport.period_label(date_range), size: 9, color: MUTED
        pdf.move_down 10
        draw_rule(pdf)
      end

      def subject_line
        [ StatementExport.unit_label(tenancy), StatementExport.property_label(tenancy) ].join(" · ")
      end

      def draw_balances(pdf, result)
        rows = [
          [ "Opening balance before #{opening_label}", StatementExport.balance(result.opening_balance_cents) ],
          [ "Closing balance as of #{closing_label}", StatementExport.balance(result.closing_balance_cents) ]
        ]

        options = {
          width: pdf.bounds.width,
          column_widths: { 0 => pdf.bounds.width - 170, 1 => 170 },
          cell_style: { size: 10, borders: NO_BORDERS, padding: [ 3, 0, 3, 0 ] }
        }

        pdf.table(rows, options) do |table|
          table.column(0).text_color = MUTED
          table.column(1).text_color = INK
          table.column(1).align = :right
          table.column(1).font_style = :bold
        end

        pdf.move_down 14
        draw_rule(pdf)
      end

      def opening_label
        from = date_range.from
        from ? StatementExport.long_date(from) : "the first entry"
      end

      def closing_label
        StatementExport.long_date(date_range.through || Date.current)
      end

      def draw_account_rows(pdf, rows)
        if rows.empty?
          pdf.text "No account activity in this period.", size: 10, color: MUTED
          return
        end

        data = [ ACCOUNT_COLUMNS.dup ]
        rows.each do |row|
          data << [
            StatementExport.long_date(row.occurred_on),
            StatementExport.activity_label(row),
            StatementExport.statement_notes(row),
            StatementExport.signed_money(row.amount_cents),
            StatementExport.balance(row.running_balance_cents)
          ]
        end

        draw_rows(pdf, data, ACCOUNT_WIDTHS, [ 3, 4 ], inactive_indexes(rows))
      end

      def draw_activity_rows(pdf, rows)
        if rows.empty?
          pdf.text "No financial activity in this period.", size: 10, color: MUTED
          return
        end

        data = [ ACTIVITY_COLUMNS.dup ]
        rows.each do |row|
          data << [
            StatementExport.long_date(row.occurred_on),
            StatementExport.event_label(row),
            StatementExport.party_name(row),
            StatementExport.audit_note(row),
            StatementExport.signed_money(row.amount_cents)
          ]
        end

        draw_rows(pdf, data, ACTIVITY_WIDTHS, [ 4 ], inactive_indexes(rows))
      end

      # Voided and corrected rows are muted the way the page dims them, while
      # the Notes column keeps saying so in words.
      def inactive_indexes(rows)
        rows.each_with_index.filter_map { |row, index| index + 1 unless row.active? }
      end

      def draw_rows(pdf, data, column_widths, right_aligned, muted_rows)
        options = {
          header: true,
          width: pdf.bounds.width,
          column_widths: column_widths,
          cell_style: {
            size: 9,
            text_color: INK,
            borders: ROW_BORDERS,
            border_width: 0.5,
            border_color: HAIRLINE,
            padding: [ 6, 4, 6, 0 ]
          }
        }

        pdf.table(data, options) do |table|
          table.row(0).size = 8
          table.row(0).font_style = :bold
          table.row(0).text_color = MUTED
          right_aligned.each { |index| table.column(index).align = :right }
          muted_rows.each { |index| table.row(index).text_color = FAINT }
        end
      end

      def draw_footnotes(pdf)
        pdf.move_down 16
        pdf.text StatementExport::AUDIT_NOTE, size: 8, color: MUTED
        pdf.move_down 3
        pdf.text "Generated #{StatementExport.long_date(Date.current)} by Yanushi.", size: 8, color: MUTED
      end

      def draw_page_numbers(pdf)
        pdf.number_pages("Page <page> of <total>", {
          at: [ 0, -20 ],
          width: pdf.bounds.width,
          align: :right,
          size: 8
        })
      end

      def draw_rule(pdf)
        pdf.stroke_color HAIRLINE
        pdf.stroke_horizontal_rule
        pdf.move_down 12
      end
  end
end

module Tenancies
  # Shared vocabulary for the tenant account statement exports.
  #
  # The PDF and the CSV have to say the same thing as
  # `tenancies/statement.html.erb`: the same money strings, the same audit
  # notes, the same period. Keeping that vocabulary in one place is what stops
  # the two documents from drifting apart, or away from the page.
  #
  # Every string that reaches a document goes through `text` first. Prawn's
  # built-in fonts only cover Windows-1252, and `signed_money_cents` emits a
  # real minus sign (U+2212), which is not in that set: without this, a single
  # payment row would fail the whole download.
  module StatementExport
    extend self

    MINUS = "−".freeze
    DASH = "—".freeze
    ACCOUNT_TITLE = "Tenant account statement".freeze
    ACTIVITY_TITLE = "Tenancy financial activity".freeze

    # Reversed and voided rows stay in the document and are labeled. This is an
    # accounting record: dropping them would hide the correction from whoever
    # is reconciling it.
    AUDIT_NOTE = "Voided and corrected entries stay listed and are labeled; " \
                 "each correcting entry appears as its own row.".freeze

    def title(view_mode)
      view_mode.to_s == "all" ? ACTIVITY_TITLE : ACCOUNT_TITLE
    end

    def tenant_names(tenancy)
      parties = tenancy.primary_tenant_parties
      parties = tenancy.all_tenant_parties if parties.empty?
      names = parties.filter_map { |party| party.display_name.presence }
      names.empty? ? "No tenant on record" : text(names.to_sentence)
    end

    def unit_label(tenancy)
      text(tenancy.rentable_unit.display_name)
    end

    def property_label(tenancy)
      property = tenancy.property
      property ? text(property.address) : DASH
    end

    # Label/value pairs naming the tenancy this document belongs to.
    def identity_lines(tenancy)
      [
        [ "Tenants", tenant_names(tenancy) ],
        [ "Unit", unit_label(tenancy) ],
        [ "Property", property_label(tenancy) ]
      ]
    end

    def period_label(date_range)
      through = date_range.through || Date.current

      if date_range.year
        "Calendar year #{date_range.year}"
      elsif date_range.from
        "#{long_date(date_range.from)} through #{long_date(through)}"
      else
        "Through #{long_date(through)}"
      end
    end

    def long_date(date)
      date.strftime("%b %-d, %Y")
    end

    def iso_date(date)
      date.strftime("%Y-%m-%d")
    end

    def money(cents)
      text(FormattingHelper.format_money_cents(cents))
    end

    def signed_money(cents)
      text(FormattingHelper.signed_money_cents(cents))
    end

    def balance(cents)
      text(FormattingHelper.balance_phrase_cents(cents))
    end

    # The activity column of the account statement, matching what the page
    # links: the description, falling back to the projected label.
    def activity_label(row)
      text(row.description.presence || row.label)
    end

    # The event column of the all-activity log: label, then the description
    # when it adds something, exactly as `accounting/_activity_row` reads.
    def event_label(row)
      description = row.description
      return text(row.label) if description.blank? || description == row.label

      text("#{row.label} · #{description}")
    end

    # The muted sub-line under an activity on the page, flattened into a cell.
    def statement_notes(row)
      notes = [] # : Array[String]
      notes << row.label.capitalize if row.label.present? && row.label != row.description
      notes << (row.kind == "waiver" ? "Waiver" : "Correction") if row.reversal
      if row.lifecycle_status == :corrected
        notes << "Corrected"
      elsif row.lifecycle_status == :voided
        notes << "Voided"
      end
      text(notes.join(" · "))
    end

    # The audit state of an all-activity row, blank while nothing is wrong.
    def audit_note(row)
      return "Corrected" if row.corrected?
      return "Voided" if row.voided?

      ""
    end

    # One machine-filterable word for a row's lifecycle, for the CSV.
    def status_word(row)
      return "Corrected" if row.corrected?
      return "Voided" if row.voided?

      "Active"
    end

    def party_name(row)
      party = row.party
      party ? text(party.display_name) : DASH
    end

    # Windows-1252 is what Prawn's built-in fonts can draw, and it is the safe
    # common denominator for spreadsheets too. Anything outside it is
    # transliterated rather than allowed to fail the download.
    def text(value)
      string = value.to_s.gsub(MINUS, "-")
      string.encode(Encoding::WINDOWS_1252)
      string
    rescue Encoding::UndefinedConversionError
      ActiveSupport::Inflector.transliterate(string, "?")
    end
  end
end

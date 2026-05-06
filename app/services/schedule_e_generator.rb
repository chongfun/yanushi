# Generates a filled IRS Schedule E (Form 1040) PDF for a given
# rental property and tax year using the HexaPDF gem.
#
# Usage:
#   pdf_bytes = ScheduleEGenerator.new(rental_property, 2025).call
#   send_data pdf_bytes, filename: "schedule_e.pdf", type: "application/pdf"
#
# The FIELD_MAP constant maps application data keys to the AcroForm
# field names in the IRS PDF template. Run `bin/rails schedule_e:dump_fields`
# to discover field names if the template is updated.
class ScheduleEGenerator
  # PDF field name mappings for Schedule E Part I (Page 1).
  #
  # Discovered by running `bin/rails schedule_e:dump_fields` against
  # the IRS f1040se.pdf template. Each expense line has 3 fields for
  # columns A, B, C (up to 3 properties). We fill column A (the first
  # field in each line group).
  #
  # If the IRS updates the PDF, re-run the dump_fields rake task and
  # update this mapping.
  # PDF field name mappings for Schedule E Part I (Page 1) - 2023-2025
  MAP_2023_PRESENT = {
    name:               "topmostSubform[0].Page1[0].f1_1[0]",
    ssn:                "topmostSubform[0].Page1[0].f1_2[0]",
    property_address:   "topmostSubform[0].Page1[0].Table_Line1a[0].RowA[0].f1_3[0]",
    property_type:      "topmostSubform[0].Page1[0].Table_Line1b[0].RowA[0].f1_6[0]",
    fair_rental_days:   "topmostSubform[0].Page1[0].Table_Line2[0].RowA[0].f1_9[0]",
    personal_use_days:  "topmostSubform[0].Page1[0].Table_Line2[0].RowA[0].f1_10[0]",
    rents_received:     "topmostSubform[0].Page1[0].Table_Income[0].Line3[0].f1_16[0]",
    advertising:                       "topmostSubform[0].Page1[0].Table_Expenses[0].Line5[0].f1_22[0]",
    auto_and_travel:                   "topmostSubform[0].Page1[0].Table_Expenses[0].Line6[0].f1_25[0]",
    cleaning_and_maintenance:          "topmostSubform[0].Page1[0].Table_Expenses[0].Line7[0].f1_28[0]",
    commissions:                       "topmostSubform[0].Page1[0].Table_Expenses[0].Line8[0].f1_31[0]",
    insurance:                         "topmostSubform[0].Page1[0].Table_Expenses[0].Line9[0].f1_34[0]",
    legal_and_other_professional_fees: "topmostSubform[0].Page1[0].Table_Expenses[0].Line10[0].f1_37[0]",
    management_fees:                   "topmostSubform[0].Page1[0].Table_Expenses[0].Line11[0].f1_40[0]",
    mortgage_interest:                 "topmostSubform[0].Page1[0].Table_Expenses[0].Line12[0].f1_43[0]",
    other_interest:                    "topmostSubform[0].Page1[0].Table_Expenses[0].Line13[0].f1_46[0]",
    repairs:                           "topmostSubform[0].Page1[0].Table_Expenses[0].Line14[0].f1_49[0]",
    supplies:                          "topmostSubform[0].Page1[0].Table_Expenses[0].Line15[0].f1_52[0]",
    taxes:                             "topmostSubform[0].Page1[0].Table_Expenses[0].Line16[0].f1_55[0]",
    utilities:                         "topmostSubform[0].Page1[0].Table_Expenses[0].Line17[0].f1_58[0]",
    depreciation_expense:              "topmostSubform[0].Page1[0].Table_Expenses[0].Line18[0].f1_61[0]",
    other:                             "topmostSubform[0].Page1[0].Table_Expenses[0].Line19[0].f1_64[0]",
    total_expenses:     "topmostSubform[0].Page1[0].Table_Expenses[0].Line20[0].f1_68[0]",
    net_income:         "topmostSubform[0].Page1[0].Table_Expenses[0].Line21[0].f1_71[0]",
    net_loss:           "topmostSubform[0].Page1[0].Table_Expenses[0].Line22[0].f1_74[0]",
    line_23a: "topmostSubform[0].Page1[0].f1_77[0]",
    line_23b: "topmostSubform[0].Page1[0].f1_78[0]",
    line_23c: "topmostSubform[0].Page1[0].f1_79[0]",
    line_23d: "topmostSubform[0].Page1[0].f1_80[0]",
    line_23e: "topmostSubform[0].Page1[0].f1_81[0]",
    line_24:  "topmostSubform[0].Page1[0].f1_82[0]",
    line_25:  "topmostSubform[0].Page1[0].f1_83[0]",
    line_26:  "topmostSubform[0].Page1[0].f1_84[0]"
  }.freeze

  # 2022 uses zero-padding for f1_01 through f1_09
  MAP_2022 = MAP_2023_PRESENT.merge({
    name:             "topmostSubform[0].Page1[0].f1_01[0]",
    ssn:              "topmostSubform[0].Page1[0].f1_02[0]",
    property_address: "topmostSubform[0].Page1[0].Table_Line1a[0].RowA[0].f1_03[0]",
    property_type:    "topmostSubform[0].Page1[0].Table_Line1b[0].RowA[0].f1_06[0]",
    fair_rental_days: "topmostSubform[0].Page1[0].Table_Line2[0].RowA[0].f1_09[0]"
  }).freeze

  # 2019-2021 structural changes
  MAP_2019_2021 = MAP_2023_PRESENT.merge({
    property_address: "topmostSubform[0].Page1[0].Line1[0].Table1a[0].RowA[0].f1_3[0]",
    property_type:    "topmostSubform[0].Page1[0].Line1[0].Table1b[0].RowA[0].f1_6[0]",
    rents_received:   "topmostSubform[0].Page1[0].Table_Income[0].Income[0].Line3[0].f1_16[0]"
  }).freeze

  # 2016-2018 shifts (Line 5 starts at f1_28, each line has 6 fields)
  MAP_2016_2018 = {
    name:               "topmostSubform[0].Page1[0].f1_1[0]",
    ssn:                "topmostSubform[0].Page1[0].f1_2[0]",
    property_address:   "topmostSubform[0].Page1[0].Line1[0].Table1a[0].RowA[0].f1_3[0]",
    property_type:      "topmostSubform[0].Page1[0].Line1[0].Table1b[0].RowA[0].f1_6[0]",
    fair_rental_days:   "topmostSubform[0].Page1[0].Table_Line2[0].RowA[0].f1_9[0]",
    personal_use_days:  "topmostSubform[0].Page1[0].Table_Line2[0].RowA[0].f1_10[0]",
    rents_received:     "topmostSubform[0].Page1[0].Table_Income[0].Income[0].Line3[0].f1_16[0]",
    advertising:        "topmostSubform[0].Page1[0].Table_Expenses[0].Line5[0].f1_28[0]",
    auto_and_travel:    "topmostSubform[0].Page1[0].Table_Expenses[0].Line6[0].f1_34[0]",
    cleaning_and_maintenance: "topmostSubform[0].Page1[0].Table_Expenses[0].Line7[0].f1_40[0]",
    commissions:        "topmostSubform[0].Page1[0].Table_Expenses[0].Line8[0].f1_46[0]",
    insurance:          "topmostSubform[0].Page1[0].Table_Expenses[0].Line9[0].f1_52[0]",
    legal_and_other_professional_fees: "topmostSubform[0].Page1[0].Table_Expenses[0].Line10[0].f1_58[0]",
    management_fees:    "topmostSubform[0].Page1[0].Table_Expenses[0].Line11[0].f1_64[0]",
    mortgage_interest:  "topmostSubform[0].Page1[0].Table_Expenses[0].Line12[0].f1_70[0]",
    other_interest:     "topmostSubform[0].Page1[0].Table_Expenses[0].Line13[0].f1_76[0]",
    repairs:            "topmostSubform[0].Page1[0].Table_Expenses[0].Line14[0].f1_82[0]",
    supplies:           "topmostSubform[0].Page1[0].Table_Expenses[0].Line15[0].f1_88[0]",
    taxes:              "topmostSubform[0].Page1[0].Table_Expenses[0].Line16[0].f1_94[0]",
    utilities:          "topmostSubform[0].Page1[0].Table_Expenses[0].Line17[0].f1_100[0]",
    depreciation_expense: "topmostSubform[0].Page1[0].Table_Expenses[0].Line18[0].f1_106[0]",
    other:              "topmostSubform[0].Page1[0].Table_Expenses[0].Line19[0].f1_112[0]",
    total_expenses:     "topmostSubform[0].Page1[0].Table_Expenses[0].Line20[0].f1_119[0]",
    net_income:         "topmostSubform[0].Page1[0].Table_Expenses[0].Line21[0].f1_125[0]",
    net_loss:           "topmostSubform[0].Page1[0].Table_Expenses[0].Line22[0].f1_131[0]",
    line_23a:           "topmostSubform[0].Page1[0].f1_140[0]",
    line_23b:           "topmostSubform[0].Page1[0].f1_141[0]",
    line_23c:           "topmostSubform[0].Page1[0].f1_142[0]",
    line_23d:           "topmostSubform[0].Page1[0].f1_143[0]",
    line_23e:           "topmostSubform[0].Page1[0].f1_144[0]",
    line_24:            "topmostSubform[0].Page1[0].f1_145[0]",
    line_25:            "topmostSubform[0].Page1[0].f1_146[0]",
    line_26:            "topmostSubform[0].Page1[0].f1_147[0]"
  }.freeze

  # 2011-2015 oldest conventions (p1-tX)
  MAP_2011_2015 = {
    name:               "topmostSubform[0].Page1[0].p1-t1[0]",
    ssn:                "topmostSubform[0].Page1[0].p1-t2[0]",
    property_address:   "topmostSubform[0].Page1[0].Line1[0].Pg1Table1a[0].a[0].p1-t5[0]",
    property_type:      "topmostSubform[0].Page1[0].Line1[0].Pg1Table1b[0].a[0].p1-t52[0]",
    fair_rental_days:   "topmostSubform[0].Page1[0].Line1[0].Pg1Table1a[0].c[0].p1-t9[0]",
    rents_received:     "topmostSubform[0].Page1[0].Pg1Table2[0].#subform[1].Line3[0].p1-t11[0]",
    auto_and_travel:    "topmostSubform[0].Page1[0].Pg1Table2[0].#subform[1].Line4[0].p1-t25[0]",
    cleaning_and_maintenance: "topmostSubform[0].Page1[0].Pg1Table3[0].Line7[0].p1-t39[0]",
    insurance:          "topmostSubform[0].Page1[0].Pg1Table3[0].Line6[0].p1-t33[0]",
    management_fees:    "topmostSubform[0].Page1[0].Pg1Table3[0].Line7[0].p1-t39[0]",
    other_interest:     "topmostSubform[0].Page1[0].Pg1Table3[0].Line8[0].p1-t45[0]",
    supplies:           "topmostSubform[0].Page1[0].Line1[0].Pg1Table1b[0].a[0].p1-t52[0]",
    utilities:          "topmostSubform[0].Page1[0].Pg1Table3[0].Line10[0].p1-t57[0]",
    other:              "topmostSubform[0].Page1[0].Pg1Table3[0].Line11[0].p1-t63[0]",
    total_expenses:     "topmostSubform[0].Page1[0].Pg1Table3[0].Line11[0].p1-t63[0]",
    net_income:         "topmostSubform[0].Page1[0].Pg1Table3[0].Line12[0].p1-t69[0]",
    net_loss:           "topmostSubform[0].Page1[0].Pg1Table3[0].Line12[0].p1-t69[0]",
    line_23a:           "topmostSubform[0].Page1[0].Pg1Table3[0].Line13[0].p1-t77[0]",
    line_23b:           "topmostSubform[0].Page1[0].Pg1Table3[0].Line13[0].p1-t78[0]",
    line_23c:           "topmostSubform[0].Page1[0].Pg1Table3[0].Line13[0].p1-t79[0]",
    line_23d:           "topmostSubform[0].Page1[0].Pg1Table3[0].Line13[0].p1-t80[0]",
    line_24:            "topmostSubform[0].Page1[0].Pg1Table3[0].Line13[0].p1-t82[0]",
    line_25:            "topmostSubform[0].Page1[0].Pg1Table3[0].Line14[0].p1-t83[0]",
    line_26:            "topmostSubform[0].Page1[0].Pg1Table3[0].Line14[0].p1-t84[0]"
  }.freeze

  # Maps Expense model categories to Schedule E line item keys.
  CATEGORY_TO_FIELD = {
    "advertising"                       => :advertising,
    "auto_and_travel"                   => :auto_and_travel,
    "cleaning_and_maintenance"          => :cleaning_and_maintenance,
    "commissions"                       => :commissions,
    "insurance"                         => :insurance,
    "legal_and_other_professional_fees" => :legal_and_other_professional_fees,
    "management_fees"                   => :management_fees,
    "mortgage_interest"                 => :mortgage_interest,
    "other_interest"                    => :other_interest,
    "repairs"                           => :repairs,
    "supplies"                          => :supplies,
    "taxes"                             => :taxes,
    "utilities"                         => :utilities,
    "depreciation_expense"              => :depreciation_expense,
    "other"                             => :other
  }.freeze

  def initialize(rental_property, year)
    @property = rental_property
    @year = year.to_i
  end

  def call
    require "hexapdf"

    doc = HexaPDF::Document.open(template_path)
    form = doc.acro_form

    fill_property_info(form)
    fill_income(form)
    fill_expenses(form)
    fill_totals(form)

    io = StringIO.new("".b)
    doc.write(io)
    io.string
  end

  private


  def fill_property_info(form)
    set_field(form, :property_address, @property.address)
    type_code = RentalProperty.property_types[@property.property_type] || 8
    set_field(form, :property_type, type_code.to_s)
    set_field(form, :fair_rental_days, "365")
    set_field(form, :personal_use_days, "0")
  end

  def fill_income(form)
    set_field(form, :rents_received, format_amount(rents_received))
  end

  def fill_expenses(form)
    expenses_by_category.each do |category, amount|
      field_key = CATEGORY_TO_FIELD[category]
      next unless field_key

      set_field(form, field_key, format_amount(amount))
    end
  end

  def fill_totals(form)
    # Line 20 — Total expenses
    set_field(form, :total_expenses, format_amount(total_expenses))

    # Lines 21/22 — Net income or net loss (per-property column A)
    net = net_income
    if net >= 0
      set_field(form, :net_income, format_amount(net))
    else
      set_field(form, :net_loss, format_amount(net.abs))
    end

    # Lines 23a–26 — Row totals summary (for a single-property filer the
    # column-A value equals the row total).

    # 23a: Total of all Line 3 amounts (rents received)
    set_field(form, :line_23a, format_amount(rents_received))

    # 23b: Total of all Line 4 amounts (royalties) — not applicable, leave blank

    # 23c: Total of all Line 18 amounts (depreciation)
    depreciation = expenses_by_category["depreciation_expense"] || 0
    set_field(form, :line_23c, format_amount(depreciation)) if depreciation > 0

    # 23d: Total of all Line 19 amounts (other expenses)
    other = expenses_by_category["other"] || 0
    set_field(form, :line_23d, format_amount(other)) if other > 0

    # 23e: Total of all Line 20 amounts (total expenses)
    set_field(form, :line_23e, format_amount(total_expenses))

    # 24: Add positive amounts from Line 21 — blank when there is a net loss
    if net >= 0
      set_field(form, :line_24, format_amount(net))
    end

    # 25: Losses allowed — for simple cases equals the net loss on Line 22
    if net < 0
      set_field(form, :line_25, format_amount(net.abs))
    end

    # 26: Combine lines 24 and 25 (signed net income or loss)
    set_field(form, :line_26, format_amount(net))
  end

  def set_field(form, key, value)
    field_name = field_map[key]
    return unless field_name

    field = form.field_by_name(field_name)
    return unless field

    field.field_value = value.to_s
  rescue HexaPDF::Error => e
    Rails.logger.warn("ScheduleEGenerator: Could not set #{key} (#{field_name}): #{e.message}")
  end

  def field_map
    @field_map ||= case @year
    when 2023..2025 then MAP_2023_PRESENT
    when 2022       then MAP_2022
    when 2019..2021 then MAP_2019_2021
    when 2016..2018 then MAP_2016_2018
    when 2011..2015 then MAP_2011_2015
    else MAP_2023_PRESENT
    end
  end

  class TemplateMissingError < StandardError; end

  def template_path
    path = Rails.root.join("app/assets/pdfs/f1040se--#{@year}.pdf")
    return path if File.exist?(path)

    raise TemplateMissingError, "No Schedule E PDF template found for year #{@year}"
  end

  def format_amount(amount)
    amount.to_i.to_s
  end

  # --- Data queries ---

  def date_range
    start_date = Date.new(@year, 1, 1)
    start_date..start_date.end_of_year
  end

  def rents_received
    rent_sum = @property.rent_payments
                 .where(payment_date: date_range)
                 .sum(:amount)

    rent_sum + utility_payment_total
  end

  def utility_payment_total
    @utility_payment_total ||= @property.utility_payments
                                 .where(payment_date: date_range)
                                 .sum(:amount)
  end

  def expenses_by_category
    @expenses_by_category ||= @property.expenses
                                .where(expense_date: date_range)
                                .group(:category)
                                .sum(:amount)
  end

  def total_expenses
    @total_expenses ||= expenses_by_category.values.sum
  end

  def net_income
    rents_received - total_expenses
  end
end

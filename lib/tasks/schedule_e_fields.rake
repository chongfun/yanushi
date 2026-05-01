namespace :schedule_e do
  desc "Dump all AcroForm field names from the Schedule E PDF template"
  task dump_fields: :environment do
    require "hexapdf"
    pdf_path = Rails.root.join("app/assets/pdfs/f1040se.pdf")

    unless File.exist?(pdf_path)
      puts "ERROR: PDF template not found at #{pdf_path}"
      puts "Download the Schedule E form from https://www.irs.gov/pub/irs-pdf/f1040se.pdf"
      exit 1
    end

    doc = HexaPDF::Document.open(pdf_path)

    unless doc.acro_form
      puts "ERROR: No AcroForm found in the PDF. This file may use XFA format."
      exit 1
    end

    puts "Schedule E PDF Form Fields"
    puts "=" * 80
    doc.acro_form.each_field do |field|
      puts "#{field.full_field_name}"
      puts "  Type:  #{field.field_type}"
      puts "  Value: #{field.field_value.inspect}"
      puts ""
    end
  end
end

# app/services/payment_receipts/ingestion.rb
module PaymentReceipts
  class Ingestion
    PARSERS = {
      "zelle" => Parsers::Zelle,
      "venmo" => Parsers::Venmo
    }.freeze

    def call(user:, pdf_path_or_io:, source: "pdf_upload")
      # Extract text and run parsing in the user's local timezone context
      Time.use_zone(user.timezone) do
        pdf_bytes = read_pdf_bytes(pdf_path_or_io)
        raw_text = extract_text(pdf_path_or_io)
        receipt_type = detect_type(raw_text)
        parser = (PARSERS[receipt_type] || Parsers::Zelle).new
        result = parser.parse(raw_text)

        filename = if pdf_path_or_io.respond_to?(:original_filename)
          pdf_path_or_io.original_filename
        elsif pdf_path_or_io.respond_to?(:path)
          File.basename(pdf_path_or_io.path)
        else
          File.basename(pdf_path_or_io.to_s)
        end
        # Fallback for string-converted IO descriptors
        filename = "receipt.pdf" if filename.blank? || filename.include?("#<")

        ingestion = if result.success?
          resolve_result = TenantResolver.new.resolve(user, result.payer_name, result.payer_username)
          tenant = resolve_result.tenant
          lease = tenant&.leases&.find { |l| active_lease?(l, result.payment_date) }

          PaymentReceiptIngestion.new(
            user: user,
            source: source,
            receipt_type: result.receipt_type,
            status: resolve_result.status,
            payer_name: result.payer_name,
            payer_username: result.payer_username,
            amount: result.amount,
            payment_date: result.payment_date,
            payment_method: result.payment_method,
            transaction_number: result.transaction_number,
            raw_text: result.raw_text,
            tenant: tenant,
            lease: lease
          )
        else
          PaymentReceiptIngestion.new(
            user: user,
            source: source,
            receipt_type: receipt_type,
            status: :failed,
            raw_text: raw_text,
            error_message: result.error_message
          )
        end

        ingestion.attachment_file = pdf_bytes
        ingestion.attachment_filename = filename
        ingestion.attachment_content_type = "application/pdf"

        ingestion.save
        ingestion
      end
    end

    private

    def read_pdf_bytes(pdf_path_or_io)
      if pdf_path_or_io.respond_to?(:read) && pdf_path_or_io.respond_to?(:rewind)
        pdf_path_or_io.rewind
        bytes = pdf_path_or_io.read
        pdf_path_or_io.rewind
        bytes
      elsif pdf_path_or_io.respond_to?(:path)
        File.binread(pdf_path_or_io.path)
      else
        File.binread(pdf_path_or_io.to_s)
      end
    end

    def extract_text(pdf_path_or_io)
      require "hexapdf"

      doc = if pdf_path_or_io.respond_to?(:read) && pdf_path_or_io.respond_to?(:seek)
        HexaPDF::Document.new(io: pdf_path_or_io)
      elsif pdf_path_or_io.respond_to?(:path)
        HexaPDF::Document.open(pdf_path_or_io.path.to_s)
      else
        HexaPDF::Document.open(pdf_path_or_io.to_s)
      end

      # Strictly enforce 1-page/1-payment checks
      raise PaymentReceipts::ParsingError, "Multi-page statement PDFs are not supported" if doc.pages.count > 1

      page = doc.pages.first
      extractor = doc.task(:smart_text_extractor) rescue nil

      if extractor
        extractor.text(page)
      else
        page.extract_text rescue ""
      end
    end

    def detect_type(text)
      if text.match?(/Transaction ID\s+\d+/i) || text.match?(/venmo/i)
        "venmo"
      elsif text.match?(/zelle/i) || text.match?(/chase/i) || text.match?(/Transaction number/i)
        "zelle"
      else
        "unknown"
      end
    end

    def active_lease?(lease, payment_date)
      return true if lease.month_to_month?
      return true unless lease.termination_date
      date = payment_date || Date.current
      date >= lease.commencement_date && date <= lease.termination_date
    end
  end
end

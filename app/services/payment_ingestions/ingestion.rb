module PaymentIngestions
  class Ingestion
    PARSERS = {
      "zelle" => Parsers::Zelle,
      "venmo" => Parsers::Venmo
    }.freeze

    def call(user:, pdf_path_or_io:, source: "pdf_upload")
      # Extract text and run parsing in the user's local timezone context
      Time.use_zone(user.timezone) do
        require "stringio"
        require "hexapdf"

        pdf_bytes, filename, page_count, raw_text, payment_document = extract_pdf_data(pdf_path_or_io, user)

        receipt_type = detect_type(raw_text)

        if receipt_type == "unknown"
          raise PaymentIngestions::ParsingError, "Unrecognized document format"
        end

        if receipt_type != "chase_statement" && page_count > 1
          raise PaymentIngestions::ParsingError, "Multi-page statement PDFs are not supported"
        end

        # Parse results
        parser_results = if receipt_type == "chase_statement"
          Parsers::ChaseStatement.new.parse(raw_text)
        else
          parser = PARSERS[receipt_type].new
          res = parser.parse(raw_text)
          res.is_a?(Array) ? res : [ res ]
        end

        ingestions = build_ingestions(
          user: user,
          source: source,
          receipt_type: receipt_type,
          parser_results: parser_results,
          raw_text: raw_text,
          payment_document: payment_document
        )

        # Raise error if no matching tenant transactions found in Chase statement
        if receipt_type == "chase_statement" && ingestions.empty?
          raise PaymentIngestions::ParsingError, "No matching tenant transactions found"
        end

        # Save payment_document if we have at least one ingestion, or if it was a single receipt (even if failed)
        if ingestions.any? || receipt_type != "chase_statement"
          payment_document.save! if payment_document.new_record?
          ingestions.each(&:save!)
        end

        # Return array of saved ingestions if it's a statement, otherwise return the single ingestion record
        if receipt_type == "chase_statement"
          ingestions
        else
          ingestions.first || PaymentIngestion.new(
            user: user,
            source: source,
            receipt_type: receipt_type,
            status: :failed,
            raw_text: raw_text,
            payment_document: payment_document
          )
        end
      end
    end

    private

      def extract_pdf_data(pdf_path_or_io, user)
        if pdf_path_or_io.is_a?(PaymentDocument)
          payment_document = pdf_path_or_io
          pdf_bytes = payment_document.has_attribute?(:attachment_file) ? payment_document.attachment_file : PaymentDocument.where(id: payment_document.id).pluck(:attachment_file).first
          raise PaymentIngestions::ParsingError, "Payment document is missing attachment data" unless pdf_bytes

          filename = payment_document.attachment_filename
          io = StringIO.new(pdf_bytes)
          doc = HexaPDF::Document.new(io: io)
        else
          pdf_bytes = read_pdf_bytes(pdf_path_or_io)

          doc = if pdf_path_or_io.respond_to?(:read) && pdf_path_or_io.respond_to?(:seek)
            HexaPDF::Document.new(io: pdf_path_or_io)
          elsif pdf_path_or_io.respond_to?(:path)
            HexaPDF::Document.open(pdf_path_or_io.path.to_s)
          else
            HexaPDF::Document.open(pdf_path_or_io.to_s)
          end

          filename = if pdf_path_or_io.respond_to?(:original_filename)
            pdf_path_or_io.original_filename
          elsif pdf_path_or_io.respond_to?(:path)
            File.basename(pdf_path_or_io.path)
          else
            File.basename(pdf_path_or_io.to_s)
          end
          filename = "receipt.pdf" if filename.blank? || filename.include?("#<")

          payment_document = PaymentDocument.new(
            user: user,
            attachment_file: pdf_bytes,
            attachment_filename: filename,
            attachment_content_type: "application/pdf"
          )
        end

        page_count = doc.pages.count

        raw_text = doc.pages.map do |page|
          extractor = doc.task(:smart_text_extractor) rescue nil
          if extractor
            extractor.text(page)
          else
            page.extract_text rescue ""
          end
        end.join("\n")

        [ pdf_bytes, filename || "receipt.pdf", page_count, raw_text, payment_document ]
      end

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

      def detect_type(text)
        if text.match?(/CHASE TOTAL CHECKING/i) && text.match?(/TRANSACTION DETAIL/i)
          "chase_statement"
        elsif text.match?(/Transaction ID\s+\d+/i) || text.match?(/venmo/i)
          "venmo"
        elsif text.match?(/zelle/i) || text.match?(/Transaction number/i) || text.match?(/sent you money/i)
          "zelle"
        else
          "unknown"
        end
      end

      def build_ingestions(user:, source:, receipt_type:, parser_results:, raw_text:, payment_document:)
        ingestions = [] # : Array[PaymentIngestion]

        parser_results.each do |parser_result|
          if successful_result?(parser_result)
            result = result_payload(parser_result)
            resolve_result = unwrap_result(TenantResolver.new.resolve(user, result.payer_name, result.payer_username))

            if receipt_type == "chase_statement" && resolve_result.status.to_s == "unmatched"
              next
            end

            party = resolve_result.party
            status = resolve_result.status
            tenancy = nil

            if party
              active_tenancies = party.tenancies.select { |t| t.active?(result.payment_date || Date.current) }
              if active_tenancies.size == 1
                tenancy = active_tenancies.first
              elsif active_tenancies.size > 1
                status = :ambiguous if status.to_s == "matched"
              end
            end

            ingestions << PaymentIngestion.new(
              user: user,
              source: source,
              receipt_type: result.receipt_type,
              status: status,
              payer_name: result.payer_name,
              payer_username: result.payer_username,
              amount: result.amount,
              payment_date: result.payment_date,
              payment_method: result.payment_method,
              transaction_number: result.transaction_number,
              raw_text: result.raw_text,
              party: party,
              tenancy: tenancy,
              payment_document: payment_document
            )
          else
            result = result_payload(parser_result)

            unless receipt_type == "chase_statement"
              ingestions << PaymentIngestion.new(
                user: user,
                source: source,
                receipt_type: receipt_type,
                status: :failed,
                raw_text: raw_text,
                error_message: result.error_message,
                payment_document: payment_document
              )
            end
          end
        end

        ingestions
      end

      def unwrap_result(result)
        result_payload(result)
      end

      def successful_result?(result)
        result.respond_to?(:success?) && result.success?
      end

      def result_payload(result)
        return result.value! if successful_result?(result) && result.respond_to?(:value!)
        return result.failure if result.respond_to?(:failure?) && result.failure? && result.respond_to?(:failure)

        result
      end
  end
end

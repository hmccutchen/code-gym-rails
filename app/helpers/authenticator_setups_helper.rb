module AuthenticatorSetupsHelper
  XML_DECLARATION = '<?xml version="1.0" standalone="yes"?>'.freeze

  def qr_code_svg(uri)
    svg = RQRCode::QRCode.new(uri).as_svg(module_size: 4, use_path: true, viewbox: true, color: "000", fill: "fff",
                                         svg_attributes: { class: "qr-code", role: "img",
                                                           "aria-label": t("authenticators.show.qr_alt") })
    svg.delete_prefix(XML_DECLARATION).html_safe
  end

  def grouped_key(secret)
    secret.scan(/.{1,4}/).join(" ")
  end
end

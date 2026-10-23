module TwoFactorSetupsHelper
  def two_factor_qr_svg(user, secret)
    uri = user.otp_provisioning_uri(user.email, otp_secret: secret, issuer: t("app_name"))
    RQRCode::QRCode.new(uri).as_svg(module_size: 4, standalone: true, use_path: true).html_safe
  end
end

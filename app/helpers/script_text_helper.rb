module ScriptTextHelper
  # On <body>, since a module runs before every other element is certain to be there.
  def script_text_attributes
    tag.attributes(data: { signed_out_text: t("request.signed_out"), save_failed_text: t("save_status.generic") })
  end
end

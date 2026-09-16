defmodule Cloudex.CloudinaryApi do
  @moduledoc """
  The live API implementation for Cloudinary uploading
  """

  @base_url "https://api.cloudinary.com/v1_1/"
  @cloudinary_headers [
    {"Content-Type", "application/x-www-form-urlencoded"},
    {"Accept", "application/json"}
  ]

  @json_library Application.compile_env(:cloudex, :json_library, Jason)

  @doc """
  Upload either a file or url to cloudinary
  `opts` can contain:
    %{resource_type: "video"}
  which will cause a video upload to occur.
  returns {:ok, %UploadedFile{}} containing all the information from cloudinary
  or {:error, "reason"} — a source Cloudinary rejects as too large (a `413`, or its own
  max-file-size validation) returns {:error, :source_too_large} specifically, so a caller
  can retry with a smaller source rather than treat it like any other failure.
  """
  @spec upload(String.t() | {:ok, String.t()}, map) ::
          {:ok, Cloudex.UploadedImage.t()} | {:error, any}
  def upload(item, opts \\ %{})
  def upload({:ok, item}, opts) when is_binary(item), do: upload(item, opts)

  def upload(item, opts) when is_binary(item) do
    case item do
      "http://" <> _rest -> upload_url(item, opts)
      "https://" <> _rest -> upload_url(item, opts)
      "s3://" <> _rest -> upload_url(item, opts)
      _ -> upload_file(item, opts)
    end
  end

  def upload(invalid_item, _opts) do
    {
      :error,
      "Upload/1 only accepts a String.t or {:ok, String.t}, received: #{inspect(invalid_item)}"
    }
  end

  @doc """
  Deletes an image given a public id
  """
  @spec delete(String.t(), map) :: {:ok, %Cloudex.DeletedImage{}} | {:error, any}
  def delete(item, opts \\ %{})

  def delete(item, opts) when is_bitstring(item) do
    case delete_file(item, opts) do
      {:ok, response} -> {:ok, %Cloudex.DeletedImage{public_id: item, response: response}}
      error -> error
    end
  end

  def delete(invalid_item, _opts) do
    {:error, "delete/1 only accepts valid public id, received: #{inspect(invalid_item)}"}
  end

  @doc """
  Deletes images given their prefix
  """
  @spec delete_prefix(String.t(), map) :: {:ok, String.t()} | {:error, any}
  def delete_prefix(prefix, opts \\ %{})

  def delete_prefix(prefix, opts) when is_bitstring(prefix) do
    case delete_by_prefix(prefix, opts) do
      {:ok, _} -> {:ok, prefix}
      error -> error
    end
  end

  def delete_prefix(invalid_prefix, _opts) do
    {:error, "delete_prefix/1 only accepts a valid prefix, received: #{inspect(invalid_prefix)}"}
  end

  @doc """
    Converts the json result from cloudinary to a %UploadedImage{} struct
  """
  @spec json_result_to_struct(map, String.t()) :: %Cloudex.UploadedImage{}
  def json_result_to_struct(result, source) do
    converted = Enum.map(result, fn {k, v} -> {String.to_atom(k), v} end) ++ [source: source]
    struct(%Cloudex.UploadedImage{}, converted)
  end

  @spec upload_file(String.t(), map) :: {:ok, %Cloudex.UploadedImage{}} | {:error, any}
  defp upload_file(file_path, opts) do
    options =
      opts
      |> extract_cloudinary_opts
      |> prepare_opts
      |> sign
      |> unify
      |> Map.to_list()

    body = {:multipart, [{:file, file_path} | options]}

    post(body, file_path, opts)
  end

  @spec extract_cloudinary_opts(map) :: map
  defp extract_cloudinary_opts(opts) do
    Map.delete(opts, :resource_type)
  end

  @spec upload_url(String.t(), map) :: {:ok, %Cloudex.UploadedImage{}} | {:error, any}
  defp upload_url(url, opts) do
    opts
    |> Map.merge(%{file: url})
    |> prepare_opts
    |> sign
    |> URI.encode_query()
    |> post(url, opts)
  end

  defp credentials do
    [
      hackney: [
        basic_auth: {Cloudex.Settings.get(:api_key), Cloudex.Settings.get(:secret)},
        timeout: 60_000,
        recv_timeout: 60_000,
        # Force HTTP/1.1: hackney 4.x auto-negotiates HTTP/2 via ALPN, and its h2
        # stack mishandles large request bodies over pooled connections — the
        # multipart file upload arrives with no `file` part, so Cloudinary rejects
        # it with "Missing required parameter - file". Mirrors the ExAws HTTP/1.1
        # workaround (walnut IE-129 / CORE-3775).
        protocols: [:http1],
        # Dedicated pool, isolated from the app-wide `:default` hackney pool
        # every other outgoing HTTP call shares. CORE-3860's http1 override
        # still left one intermittent "Missing required parameter - file"
        # failure days after deploy; giving Cloudinary uploads their own pool
        # rules out any interaction with unrelated traffic on the shared pool
        # (load_regulation slot contention, TCP connections churned by other
        # hosts, etc.) as a contributing factor.
        pool: :cloudinary_uploads
      ]
    ]
  end

  @spec delete_file(bitstring, map) ::
          {:ok, HTTPoison.Response.t() | HTTPoison.AsyncResponse.t()}
          | {:error, HTTPoison.Error.t()}
  defp delete_file(item, opts) do
    HTTPoison.delete(delete_url_for(opts, item), @cloudinary_headers, credentials())
  end

  defp delete_url_for(opts, item) do
    "#{@base_url}#{Cloudex.Settings.get(:cloud_name)}/resources/#{Map.get(opts, :resource_type, "image")}/#{Map.get(opts, :type, "upload")}?public_ids[]=#{item}"
  end

  @spec delete_file(bitstring, map) ::
          {:ok, HTTPoison.Response.t() | HTTPoison.AsyncResponse.t()}
          | {:error, HTTPoison.Error.t()}
  defp delete_by_prefix(prefix, opts) do
    HTTPoison.delete(delete_prefix_url_for(opts, prefix), @cloudinary_headers, credentials())
  end

  defp delete_prefix_url_for(%{resource_type: resource_type}, prefix) do
    delete_prefix_url(resource_type, prefix)
  end

  defp delete_prefix_url_for(_, prefix), do: delete_prefix_url("image", prefix)

  defp delete_prefix_url(resource_type, prefix) do
    "#{@base_url}#{Cloudex.Settings.get(:cloud_name)}/resources/#{resource_type}/upload?prefix=#{prefix}"
  end

  @spec post(tuple | String.t(), binary, map) :: {:ok, %Cloudex.UploadedImage{}} | {:error, any}
  defp post(body, source, opts) do
    with {:ok, raw_response} <- common_post(body, opts) do
      handle_response(raw_response.status_code, raw_response.body, source)
    end
  end

  defp common_post(body, opts) do
    HTTPoison.request(:post, url_for(opts), body, @cloudinary_headers, credentials())
  end

  defp context_to_list(context) do
    context
    |> Enum.reduce([], fn {k, v}, acc -> acc ++ ["#{k}=#{v}"] end)
    |> Enum.join("|")
  end

  @spec prepare_opts(map | list) :: map

  defp prepare_opts(%{tags: tags} = opts) when is_list(tags),
    do: %{opts | tags: Enum.join(tags, ",")} |> prepare_opts()

  defp prepare_opts(%{context: context} = opts) when is_map(context),
    do: %{opts | context: context_to_list(context)} |> prepare_opts()

  defp prepare_opts(opts), do: opts

  defp url_for(%{resource_type: resource_type}), do: url(resource_type)
  defp url_for(_), do: url("image")

  def url(resource_type) do
    "#{@base_url}#{Cloudex.Settings.get(:cloud_name)}/#{resource_type}/upload"
  end

  # Cloudinary rejects an oversized upload two different ways: a `413 Request Entity Too
  # Large` from nginx, whose body is an HTML error page rather than JSON (so blindly
  # decoding it, the previous behaviour here, raised instead of returning a clean error);
  # and, separately, its own account-level max-file-size validation, returned as ordinary
  # JSON with a message starting "File size too large." — both permanent-as-is,
  # non-retryable rejections, so both are classified the same way rather than left for a
  # caller to puzzle out from a decode exception or an opaque message string. Mirrors
  # walnut_monorepo's `Api.Storylines.CapturedScreenAssets.CloudinaryUploader` (CORE-6291),
  # which special-cases the same two shapes for its own (non-Cloudex) upload path.
  @spec handle_response(non_neg_integer, binary, String.t()) ::
          {:error, any} | {:ok, %Cloudex.UploadedImage{}}
  defp handle_response(413, _raw, _source), do: {:error, :source_too_large}

  defp handle_response(status_code, raw, source) do
    case @json_library.decode(raw) do
      {:ok, %{"error" => %{"message" => "File size too large" <> _}}} ->
        {:error, :source_too_large}

      {:ok, %{"error" => %{"message" => error}}} ->
        {:error, error}

      {:ok, response} when status_code in 200..299 ->
        {:ok, json_result_to_struct(response, source)}

      {:ok, response} ->
        {:error, {:cloudinary_http_error, status_code, response}}

      {:error, _decode_error} ->
        {:error, {:cloudinary_http_error, status_code, raw}}
    end
  end

  #  Unifies hybrid map into string-only key map.
  #  ie. `%{a: 1, "b" => 2} => %{"a" => 1, "b" => 2}`
  @spec unify(map) :: map
  defp unify(data), do: Enum.reduce(data, %{}, fn {k, v}, acc -> Map.put(acc, "#{k}", v) end)

  @spec sign(map) :: map
  defp sign(data) do
    timestamp = current_time()

    data_without_secret =
      data
      |> Map.drop([:file, :resource_type])
      |> Map.merge(%{"timestamp" => timestamp})
      |> Enum.map(fn {key, val} -> "#{key}=#{val}" end)
      |> Enum.sort()
      |> Enum.join("&")

    signature = sha(data_without_secret <> Cloudex.Settings.get(:secret))

    Map.merge(
      data,
      %{
        "timestamp" => timestamp,
        "signature" => signature,
        "api_key" => Cloudex.Settings.get(:api_key)
      }
    )
  end

  @spec sha(String.t()) :: String.t()
  defp sha(query) do
    :sha
    |> :crypto.hash(query)
    |> Base.encode16()
    |> String.downcase()
  end

  @spec current_time :: String.t()
  defp current_time do
    Timex.now()
    |> Timex.to_unix()
    |> round
    |> Integer.to_string()
  end
end

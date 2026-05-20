defmodule Protox do
  @moduledoc false
  # Minimal protox stubs — provides only the functions called by the protox-generated
  # lib/zypi/v1_pb.ex. This replaces the full protox 2.x library (~10K lines) with a
  # ~300-line hand-rolled compatibility layer. No protoc needed. No Hex deps needed.
  # The generated v1_pb.ex imports this module directly.

  # ---------------------------------------------------------------------------
  # Version check (no-op — we are the runtime)
  # ---------------------------------------------------------------------------
  @spec check_generator_version(non_neg_integer()) :: :ok
  def check_generator_version(_version), do: :ok

  # ---------------------------------------------------------------------------
  # Exceptions
  # ---------------------------------------------------------------------------
  defmodule EncodingError do
    defexception [:field, :message]

    @doc false
    def new(field, message) do
      %__MODULE__{field: field, message: message}
    end
  end

  defmodule RequiredFieldsError do
    defexception [:fields]
  end

  defmodule DecodingError do
    defexception [:message]

    @doc false
    def new(_bytes, message) do
      %__MODULE__{message: message}
    end
  end

  defmodule IllegalTagError do
    defexception []
  end

  # ---------------------------------------------------------------------------
  # Type aliases
  # ---------------------------------------------------------------------------
  defmodule Types do
    @type tag :: atom()
  end

  # ---------------------------------------------------------------------------
  # Schema structs (minimal — for protox-compatible schema/0 functions)
  # ---------------------------------------------------------------------------
  defmodule MessageSchema do
    defstruct [:name, :syntax, :fields, :oneofs, :extensions]
    @type t :: %__MODULE__{}
  end

  defmodule Field do
    defstruct [:name, :kind, :label, :tag, :type, :json_name, :oneof]
    @type t :: %__MODULE__{}
  end

  defmodule Scalar do
    defstruct [:default_value]
    @type t :: %__MODULE__{}
  end

  defmodule OneOf do
    defstruct [:name, :parent_name, :fields]
  end

  # ---------------------------------------------------------------------------
  # Default values (protox's type → default_value mapping)
  # ---------------------------------------------------------------------------
  defmodule Default do
    @spec default(atom()) :: term()
    def default(:bool), do: false
    def default(:int32), do: 0
    def default(:uint32), do: 0
    def default(:uint64), do: 0
    def default(:string), do: ""
    def default(:bytes), do: <<>>
    def default(_), do: nil
  end

  # ---------------------------------------------------------------------------
  # Merge (shallow merge of message structs)
  # ---------------------------------------------------------------------------
  defmodule MergeMessage do
    @spec merge(map(), map()) :: map()
    def merge(a, b) when is_map(a) and is_map(b) do
      Map.merge(a, b)
    end
  end

  # ---------------------------------------------------------------------------
  # Protobuf Varint encoding/decoding
  # ---------------------------------------------------------------------------
  defmodule Varint do
    import Bitwise

    @doc "Encode integer as protobuf varint binary."
    @spec encode(non_neg_integer()) :: binary()
    def encode(n) when n < 128, do: <<n>>
    def encode(n) do
      <<n::7, 1::1, encode(n >>> 7)::binary>>
    end

    @doc "Decode a varint from binary. Returns {value, rest}."
    @spec decode(binary()) :: {non_neg_integer(), binary()}
    def decode(<<v::7, 0::1, rest::binary>>), do: {v, rest}
    def decode(<<v::7, 1::1, rest::binary>>) do
      {next, rest2} = decode(rest)
      {v + (next <<< 7), rest2}
    end
  end

  # ---------------------------------------------------------------------------
  # Protobuf wire encoding helpers
  # ---------------------------------------------------------------------------
  defmodule Encode do
    import Bitwise
    @wire_varint 0
    @wire_64bit 1
    @wire_length_delimited 2
    @wire_start_group 3
    @wire_end_group 4
    @wire_32bit 5

    @doc "Make a protobuf field key: (field_number << 3) | wire_type, as varint."
    @spec make_key_bytes(non_neg_integer(), atom()) :: {binary(), non_neg_integer()}
    def make_key_bytes(tag, wire_type) when is_atom(wire_type) do
      wt = case wire_type do
        :int32 -> @wire_varint
        :int64 -> @wire_varint
        :uint32 -> @wire_varint
        :uint64 -> @wire_varint
        :sint32 -> @wire_varint
        :sint64 -> @wire_varint
        :bool -> @wire_varint
        :enum -> @wire_varint
        :double -> @wire_64bit
        :fixed64 -> @wire_64bit
        :sfixed64 -> @wire_64bit
        :float -> @wire_32bit
        :fixed32 -> @wire_32bit
        :sfixed32 -> @wire_32bit
        :string -> @wire_length_delimited
        :bytes -> @wire_length_delimited
        :message -> @wire_length_delimited
        :packed -> @wire_length_delimited
      end
      key = tag <<< 3 ||| wt
      encoded_key = Varint.encode(key)
      {encoded_key, byte_size(encoded_key)}
    end

    @doc "Encode a string: length-delimited UTF-8 bytes."
    @spec encode_string(String.t()) :: {binary(), non_neg_integer()}
    def encode_string(s) when is_binary(s) do
      len = byte_size(s)
      len_enc = Varint.encode(len)
      value = <<len_enc::binary, s::binary>>
      {value, byte_size(value)}
    end

    @doc "Encode an int32 (varint, zigzag not applied — caller handles sign)."
    @spec encode_int32(integer()) :: {binary(), non_neg_integer()}
    def encode_int32(n) when n >= 0 do
      bytes = Varint.encode(n)
      {bytes, byte_size(bytes)}
    end
    def encode_int32(n) do
      # Negative int32 in proto3 uses 10-byte varint (sign-extended)
      bytes = Varint.encode(n &&& 0xFFFFFFFF)
      {bytes, byte_size(bytes)}
    end

    @doc "Encode a uint32 (unsigned varint)."
    @spec encode_uint32(non_neg_integer()) :: {binary(), non_neg_integer()}
    def encode_uint32(n) do
      bytes = Varint.encode(n)
      {bytes, byte_size(bytes)}
    end

    @doc "Encode a uint64 (unsigned varint)."
    @spec encode_uint64(non_neg_integer()) :: {binary(), non_neg_integer()}
    def encode_uint64(n) do
      bytes = Varint.encode(n)
      {bytes, byte_size(bytes)}
    end

    @doc "Encode a bool (varint 0 or 1)."
    @spec encode_bool(boolean()) :: {binary(), non_neg_integer()}
    def encode_bool(true), do: {<<1>>, 1}
    def encode_bool(false), do: {<<0>>, 1}

    @doc "Encode a nested message (length-delimited)."
    @spec encode_message(binary()) :: {binary(), non_neg_integer()}
    def encode_message(bytes) when is_binary(bytes) do
      len = byte_size(bytes)
      len_enc = Varint.encode(len)
      value = <<len_enc::binary, bytes::binary>>
      {value, byte_size(value)}
    end
  end

  # ---------------------------------------------------------------------------
  # Protobuf wire decoding helpers
  # ---------------------------------------------------------------------------
  defmodule Decode do
    import Bitwise
    @wire_varint 0
    @wire_64bit 1
    @wire_length_delimited 2
    @wire_start_group 3
    @wire_end_group 4
    @wire_32bit 5

    @doc "Parse a length-delimited field: returns {value_bytes, rest}."
    @spec parse_delimited(binary(), non_neg_integer()) :: {binary(), binary()}
    def parse_delimited(bytes, len) do
      <<value::binary-size(len), rest::binary>> = bytes
      {value, rest}
    end

    @doc "Parse a protobuf field key: returns {field_number, wire_type, rest}."
    @spec parse_key(binary()) :: {non_neg_integer(), non_neg_integer(), binary()}
    def parse_key(bytes) do
      {key, rest} = Varint.decode(bytes)
      field_number = key >>> 3
      wire_type = key &&& 0x07
      {field_number, wire_type, rest}
    end

    @doc "Parse an unknown field (skip over it in the stream)."
    @spec parse_unknown(non_neg_integer(), non_neg_integer(), binary()) :: {term(), binary()}
    def parse_unknown(_tag, @wire_varint, bytes) do
      {_val, rest} = Varint.decode(bytes)
      {nil, rest}
    end

    def parse_unknown(_tag, @wire_64bit, <<_::64, rest::binary>>) do
      {nil, rest}
    end

    def parse_unknown(_tag, @wire_length_delimited, bytes) do
      {len, rest} = Varint.decode(bytes)
      <<_payload::binary-size(len), rest2::binary>> = rest
      {nil, rest2}
    end

    def parse_unknown(_tag, @wire_32bit, <<_::32, rest::binary>>) do
      {nil, rest}
    end

    def parse_unknown(_tag, @wire_start_group, _bytes) do
      raise "unsupported: start group (wire type 3)"
    end

    def parse_unknown(_tag, @wire_end_group, _bytes) do
      raise "unsupported: end group (wire type 4)"
    end

    def parse_unknown(_tag, wire_type, _bytes) do
      raise "unsupported wire type: #{wire_type}"
    end

    @doc "Parse an int32 (varint)."
    @spec parse_int32(binary()) :: {integer(), binary()}
    def parse_int32(bytes) do
      {val, rest} = Varint.decode(bytes)
      # Decode signed 32-bit from 10-byte varint
      {decode_zigzag32(val), rest}
    end

    @doc "Parse a uint32 (unsigned varint)."
    @spec parse_uint32(binary()) :: {non_neg_integer(), binary()}
    def parse_uint32(bytes) do
      Varint.decode(bytes)
    end

    @doc "Parse a uint64 (unsigned varint)."
    @spec parse_uint64(binary()) :: {non_neg_integer(), binary()}
    def parse_uint64(bytes) do
      Varint.decode(bytes)
    end

    @doc "Parse a bool (varint 0 or 1)."
    @spec parse_bool(binary()) :: {boolean(), binary()}
    def parse_bool(<<0, rest::binary>>), do: {false, rest}
    def parse_bool(<<_val, rest::binary>>), do: {true, rest}

    @doc "Validate a protobuf string field is valid UTF-8."
    @spec validate_string!(binary()) :: String.t()
    def validate_string!(bytes) do
      # protox's validate_string raises on invalid UTF-8
      case :unicode.characters_to_binary(bytes) do
        s when is_binary(s) -> s
        _ -> raise "invalid UTF-8 in string field"
      end
    end

    # Zigzag decode for signed 32-bit integers
    defp decode_zigzag32(n) do
      band = Bitwise.band(n, 1)
      band * -1 * (n >>> 1) - (1 - band) * (n >>> 1)
    end
  end
end

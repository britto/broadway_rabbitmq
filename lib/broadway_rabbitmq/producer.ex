defmodule BroadwayRabbitMQ.Producer do
  @moduledoc """
  A RabbitMQ producer for Broadway.

  ## Features

    * Automatically acknowledges/rejects messages.
    * Handles connection outages using backoff for retries.

  ## Options

    * `:queue` - Required. The name of the queue. If `""`, then the queue name will
      be autogenerated by the server but for this to work you have to declare
      the queue through the `:declare` option.
    * `:connection` - Optional. Defines an AMQP URI or a set of options used by
      the RabbitMQ client to open the connection with the RabbitMQ broker. See
      `AMQP.Connection.open/1` for the full list of options.
    * `:qos` - Optional. Defines a set of prefetch options used by the RabbitMQ client.
      See `AMQP.Basic.qos/2` for the full list of options. Pay attention that the
      `:global` option is not supported by Broadway since each producer holds only one
      channel per connection.
    * `:buffer_size` - Optional, but required if `:prefetch_count` under `:qos` is
      set to `0`. Defines the size of the buffer to store events without demand.
      Can be :infinity to signal no limit on the buffer size. This is used to
      configure the GenStage producer, see the `GenStage` docs for more details.
      Defaults to `:prefetch_count * 5`.
    * `:buffer_keep` - Optional. Used in the GenStage producer configuration.
      Defines whether the `:first` or `:last` entries should be kept on the
      buffer in case the buffer size is exceeded. Defaults to `:last`.
    * `:backoff_min` - The minimum backoff interval (default: `1_000`)
    * `:backoff_max` - The maximum backoff interval (default: `30_000`)
    * `:backoff_type` - The backoff strategy, `:stop` for no backoff and
       to stop, `:exp` for exponential, `:rand` for random and `:rand_exp` for
       random exponential (default: `:rand_exp`)
    * `:metadata` - The list of AMQP metadata fields to copy (default: `[]`)
    * `:declare` - Optional. A list of options used to declare the `:queue`. The
      queue is only declared (and possibly created if not already there) if this
      option is present and not `nil`. Note that if you use `""` as the queue
      name (which means that the queue name will be autogenerated on the server),
      then every producer stage will declare a different queue. If you want all
      producer stages to consume from the same queue, use a specific queue name.
      You can still declare the same queue as many times as you want because
      queue creation is idempotent (as long as you don't use the `passive: true`
      option). For the available options, see `AMQP.Queue.declare/3`.
    * `:bindings` - Optional. a list of bindings for the `:queue`. This option
       allows you to bind the queue to one or more exchanges. Each binding is a tuple
      `{exchange_name, binding_options}` where so that the queue will be bound
      to `exchange_name` through `AMQP.Queue.bind/4` using `binding_options` as
      the options. Bindings are idempotent so you can bind the same queue to the
      same exchange multiple times.
    * `:on_success` - configures the acking behaviour for successful messages.
      See the "Acking" section below for all the possible values. Defaults to
      `:ack`. This option can also be changed for each message through
      `Broadway.Message.configure_ack/2`.
    * `:on_failure` - configures the acking behaviour for failed messages.
      See the "Acking" section below for all the possible values. Defaults to
      `:reject_and_requeue`. This option can also be changed for each message through
      `Broadway.Message.configure_ack/2`.
    * `:merge_options` - a function that takes the index of the producer in the
      Broadway topology and returns a keyword list of options. The returned options
      are merged with the other options given to the producer. This option is useful
      to dynamically change options based on the index of the producer. For example,
      you can use this option to "shard" load between a few queues where a subset of
      the producer stages is connected to each queue, or to connect producers to
      different RabbitMQ nodes (for example through partitioning). Note that the options
      are evaluated every time a connection is established (for example, in case
      of disconnections). This means that you can also use this option to choose
      different options on every reconnections. This can be particularly useful
      if you have multiple RabbitMQ URLs: in that case, you can reconnect to a different
      URL every time you reconnect to RabbitMQ, which avoids the case where the
      producer tries to always reconnect to a URL that is down.

  > Note: choose the requeue strategy carefully. If you set the value to `:never`
  or `:once`, make sure you handle failed messages properly, either by logging
  them somewhere or redirecting them to a dead-letter queue for future inspection.
  By sticking with `:always`, pay attention that requeued messages by default will
  be instantly redelivered, this may result in very high unnecessary workload.
  One way to handle this is by using [Dead Letter Exchanges](https://www.rabbitmq.com/dlx.html)
  and [TTL and Expiration](https://www.rabbitmq.com/ttl.html).

  ## Example

      Broadway.start_link(MyBroadway,
        name: MyBroadway,
        producer: [
          module:
            {BroadwayRabbitMQ.Producer,
            queue: "my_queue",
            connection: [
              username: "user",
              password: "password",
              host: "192.168.0.10"
            ],
            qos: [
              prefetch_count: 50
            ]},
          stages: 5
        ],
        processors: [
          default: []
        ]
      )

  ## Back-pressure and `:prefetch_count`

  Unlike the RabbitMQ client that has a default `:prefetch_count` = 0,
  which disables back-pressure, BroadwayRabbitMQ overwrite the default
  value to `50` enabling the back-pressure mechanism. You can still define
  it as `0`, however, if you do this, make sure the machine has enough
  resources to handle the number of messages coming from the broker, and set
  `:buffer_size` to an appropriate value.

  This is important because the BroadwayRabbitMQ producer does not work
  as a poller like BroadwaySQS. Instead, it maintains an active connection
  with a subscribed consumer that receives messages continuously as they
  arrive in the queue. This is more efficient than using the `basic.get`
  method, however, it removes the ability of the GenStage producer to control
  the demand. Therefore we need to use the `:prefetch_count` option to
  impose back-pressure at the channel level.

  ## Connection loss and backoff

  In case the connection cannot be opened or if a stablished connection is lost,
  the producer will try to reconnect using an exponential random backoff strategy.
  The strategy can be configured using the `:backoff_type` option.

  ## Unsupported options

  Currently, Broadway does not accept options for `Basic.consume/4` which
  is called internally by the producer with default values. That means options
  like `:no_ack` are not supported. If you have a scenario where you need to
  customize those options, please open an issue, so we can consider adding this
  feature.

  ## Declaring queues and binding them to exchanges

  In RabbitMQ, it's common for consumers to declare the queue they're going
  to consume from and bind it to the appropriate exchange when they start up.
  You can do these steps (either or both) when setting up your Broadway pipeline
  through the `:declare` and `:bindings` options.

      Broadway.start_link(MyBroadway,
        name: MyBroadway,
        producer: [
          module:
            {BroadwayRabbitMQ.Producer,
            queue: "my_queue",
            declare: [],
            bindings: [{"my-exchange", []}]},
          stages: 5
        ],
        processors: [
          default: []
        ]
      )

  ## Acking

  You can use the `:on_success` and `:on_failure` options to control how messages
  are acked on RabbitMQ. By default, successful messages are acked and failed
  messages are rejected. You can set `:on_success` and `:on_failure` when starting
  the RabbitMQ producer, or change them for each message through
  `Broadway.Message.configure_ack/2`.

  Here is the list of all possible values supported by `:on_success` and `:on_failure`:

    * `:ack` - acknowledge the message. RabbitMQ will mark the message as acked and
      will not redeliver it to any other consumer.

    * `:reject` - rejects the message without requeuing (basically, discards the message).
      RabbitMQ will not redeliver the message to any other consumer.

    * `:reject_and_requeue` - rejects the message and tells RabbitMQ to requeue it so
      that it can be delivered to a consumer again. `:reject_and_requeue` always
      requeues the message.

    * `:reject_and_requeue_once` - rejects the message and tells RabbitMQ to requeue it
      the first time. If a message was already requeued and redelivered, it will be
      rejected and not requeued again.

  """

  use GenStage

  require Logger

  alias Broadway.{Message, Acknowledger, Producer}
  alias BroadwayRabbitMQ.Backoff

  @behaviour Acknowledger
  @behaviour Producer

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    client = opts[:client] || BroadwayRabbitMQ.AmqpClient
    {gen_stage_opts, opts} = Keyword.split(opts, [:buffer_size, :buffer_keep])
    {success_failure_opts, opts} = split_success_failure_options(opts)

    assert_valid_success_failure_opts!(success_failure_opts)

    config = init_client!(client, opts)

    send(self(), {:connect, :no_init_client})

    prefetch_count = config[:qos][:prefetch_count]
    options = producer_options(gen_stage_opts, prefetch_count)

    {:producer,
     %{
       client: client,
       channel: nil,
       consumer_tag: nil,
       config: config,
       backoff: Backoff.new(opts),
       conn_ref: nil,
       channel_ref: nil,
       opts: opts,
       on_success: Keyword.fetch!(success_failure_opts, :on_success),
       on_failure: Keyword.fetch!(success_failure_opts, :on_failure)
     }, options}
  end

  @impl true
  def handle_demand(_incoming_demand, state) do
    {:noreply, [], state}
  end

  @impl true
  def handle_info({:basic_consume_ok, %{consumer_tag: tag}}, state) do
    {:noreply, [], %{state | consumer_tag: tag}}
  end

  # RabbitMQ sends this in a few scenarios, like if the queue this consumer
  # is consuming from gets deleted. See https://www.rabbitmq.com/consumer-cancel.html.
  def handle_info({:basic_cancel, _}, state) do
    {:noreply, [], connect(state, :init_client)}
  end

  def handle_info({:basic_cancel_ok, _}, state) do
    {:noreply, [], %{state | consumer_tag: nil}}
  end

  def handle_info({:basic_deliver, payload, meta}, state) do
    %{channel: channel, client: client, config: config} = state
    %{delivery_tag: tag, redelivered: redelivered} = meta

    ack_data = %{
      delivery_tag: tag,
      client: client,
      redelivered: redelivered,
      on_success: state.on_success,
      on_failure: state.on_failure
    }

    message = %Message{
      data: payload,
      metadata: Map.take(meta, config[:metadata]),
      acknowledger: {__MODULE__, _ack_ref = channel, ack_data}
    }

    {:noreply, [message], state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{conn_ref: ref} = state) do
    {:noreply, [], connect(state, :init_client)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{channel_ref: ref} = state) do
    {:noreply, [], connect(state, :init_client)}
  end

  def handle_info({:connect, mode}, state) when mode in [:init_client, :no_init_client] do
    {:noreply, [], connect(state, mode)}
  end

  def handle_info(_, state) do
    {:noreply, [], state}
  end

  @impl true
  def terminate(_reason, state) do
    %{client: client, channel: channel} = state

    if channel do
      client.close_connection(channel.conn)
    end

    :ok
  end

  @impl Acknowledger
  def ack(_ack_ref = channel, successful, failed) do
    ack_messages(successful, channel, :successful)
    ack_messages(failed, channel, :failed)
  end

  @impl Acknowledger
  def configure(_channel, ack_data, options) do
    assert_valid_success_failure_opts!(options)
    ack_data = Map.merge(ack_data, Map.new(options))
    {:ok, ack_data}
  end

  defp assert_valid_success_failure_opts!(options) do
    assert_supported_value = fn
      value when value in [:ack, :reject, :reject_and_requeue, :reject_and_requeue_once] ->
        :ok

      other ->
        raise ArgumentError, "unsupported value for on_success/on_failure: #{inspect(other)}"
    end

    Enum.each(options, fn
      {:on_success, value} -> assert_supported_value.(value)
      {:on_failure, value} -> assert_supported_value.(value)
      {other, _value} -> raise ArgumentError, "unsupported configure option #{inspect(other)}"
    end)
  end

  @impl Producer
  def prepare_for_draining(%{channel: nil} = state) do
    {:noreply, [], state}
  end

  def prepare_for_draining(state) do
    %{client: client, channel: channel, consumer_tag: consumer_tag} = state

    case client.cancel(channel, consumer_tag) do
      {:ok, ^consumer_tag} ->
        {:noreply, [], state}

      {:error, error} ->
        Logger.error("Could not cancel producer while draining. Channel is #{error}")
        {:noreply, [], state}
    end
  end

  defp producer_options(opts, 0) do
    if opts[:buffer_size] do
      opts
    else
      raise ArgumentError, ":prefetch_count is 0, specify :buffer_size explicitly"
    end
  end

  defp producer_options(opts, prefetch_count) do
    Keyword.put_new(opts, :buffer_size, prefetch_count * 5)
  end

  defp ack_messages(messages, channel, kind) do
    Enum.each(messages, fn msg ->
      {_module, _channel, ack_data} = msg.acknowledger

      try do
        case kind do
          :successful -> apply_ack_func(ack_data.on_success, ack_data, channel)
          :failed -> apply_ack_func(ack_data.on_failure, ack_data, channel)
        end
      catch
        kind, reason ->
          Logger.error(Exception.format(kind, reason, System.stacktrace()))
      end
    end)
  end

  defp apply_ack_func(:ack, ack_data, channel) do
    ack_data.client.ack(channel, ack_data.delivery_tag)
  end

  defp apply_ack_func(reject, ack_data, channel)
       when reject in [:reject, :reject_and_requeue, :reject_and_requeue_once] do
    options = [requeue: requeue?(reject, ack_data.redelivered)]
    ack_data.client.reject(channel, ack_data.delivery_tag, options)
  end

  defp requeue?(:reject, _redelivered), do: false
  defp requeue?(:reject_and_requeue, _redelivered), do: true
  defp requeue?(:reject_and_requeue_once, redelivered), do: !redelivered

  defp connect(state, mode) when mode in [:init_client, :no_init_client] do
    %{client: client, config: config, backoff: backoff, opts: opts} = state

    config =
      if mode == :no_init_client do
        config
      else
        init_client!(client, opts)
      end

    # TODO: Treat other setup errors properly
    case client.setup_channel(config) do
      {:ok, channel} ->
        conn_ref = Process.monitor(channel.conn.pid)
        channel_ref = Process.monitor(channel.pid)
        backoff = backoff && Backoff.reset(backoff)
        consumer_tag = client.consume(channel, config)

        %{
          state
          | channel: channel,
            config: config,
            consumer_tag: consumer_tag,
            backoff: backoff,
            conn_ref: conn_ref,
            channel_ref: channel_ref
        }

      {:error, {:auth_failure, 'Disconnected'}} ->
        handle_backoff(state)

      {:error, {:socket_closed_unexpectedly, :"connection.start"}} ->
        handle_backoff(state)

      {:error, :econnrefused} ->
        handle_backoff(state)

      {:error, :unknown_host} ->
        handle_backoff(state)
    end
  end

  defp handle_backoff(%{backoff: backoff} = state) do
    Logger.error("Cannot connect to RabbitMQ broker")

    new_backoff =
      if backoff do
        {timeout, backoff} = Backoff.backoff(backoff)
        Process.send_after(self(), {:connect, :init_client}, timeout)
        backoff
      end

    %{
      state
      | channel: nil,
        consumer_tag: nil,
        backoff: new_backoff,
        conn_ref: nil,
        channel_ref: nil
    }
  end

  defp init_client!(client, opts) do
    case client.init(opts) do
      {:ok, config} ->
        config

      {:error, message} ->
        raise ArgumentError, "invalid options given to #{inspect(client)}.init/1, " <> message
    end
  end

  defp split_success_failure_options(opts) do
    {success_failure_opts, opts} = Keyword.split(opts, [:on_success, :on_failure])
    {requeue, opts} = Keyword.pop(opts, :requeue)

    # TODO: Remove when we remove support for :requeue.
    if requeue do
      IO.warn("the :requeue option is deprecated, use :on_failure instead")
    end

    on_failure =
      Keyword.get_lazy(success_failure_opts, :on_failure, fn ->
        case requeue do
          nil -> :reject_and_requeue
          :always -> :reject_and_requeue
          :once -> :reject_and_requeue_once
          :never -> :reject
        end
      end)

    success_failure_opts = [
      on_success: Keyword.get(success_failure_opts, :on_success, :ack),
      on_failure: on_failure
    ]

    {success_failure_opts, opts}
  end
end

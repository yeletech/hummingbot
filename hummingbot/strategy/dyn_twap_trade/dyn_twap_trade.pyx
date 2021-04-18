# distutils: language=c++
from decimal import Decimal
import logging
import math
from typing import (
    List,
    Tuple,
    Optional,
    Dict
)

from hummingbot.core.clock cimport Clock
from hummingbot.logger import HummingbotLogger
from hummingbot.core.event.event_listener cimport EventListener
from hummingbot.core.data_type.limit_order cimport LimitOrder
from hummingbot.core.data_type.limit_order import LimitOrder
from hummingbot.core.network_iterator import NetworkStatus
from hummingbot.connector.exchange_base import ExchangeBase
from hummingbot.connector.exchange_base cimport ExchangeBase
from hummingbot.core.event.events import (
    OrderType,
    TradeType
)

from hummingbot.strategy.market_trading_pair_tuple import MarketTradingPairTuple
from hummingbot.strategy.strategy_base import StrategyBase

from libc.stdint cimport int64_t
from libc.stdlib cimport rand, srand, RAND_MAX
from libc.time cimport time
from hummingbot.core.data_type.order_book cimport OrderBook
from datetime import datetime

from .asset_price_delegate cimport AssetPriceDelegate
from .asset_price_delegate import AssetPriceDelegate

NaN = float("nan")
s_decimal_zero = Decimal(0)
s_decimal_neg_one = Decimal(-1)
ds_logger = None
# weak pseudorandomness is good enough for now
srand(time(NULL))

cdef class TwapTradeStrategy(StrategyBase):
    OPTION_LOG_NULL_ORDER_SIZE = 1 << 0
    OPTION_LOG_REMOVING_ORDER = 1 << 1
    OPTION_LOG_ADJUST_ORDER = 1 << 2
    OPTION_LOG_CREATE_ORDER = 1 << 3
    OPTION_LOG_MAKER_ORDER_FILLED = 1 << 4
    OPTION_LOG_STATUS_REPORT = 1 << 5
    OPTION_LOG_MAKER_ORDER_HEDGED = 1 << 6
    OPTION_LOG_ALL = 0x7fffffffffffffff
    CANCEL_EXPIRY_DURATION = 60.0

    @classmethod
    def logger(cls) -> HummingbotLogger:
        global ds_logger
        if ds_logger is None:
            ds_logger = logging.getLogger(__name__)
        return ds_logger

    def __init__(self,
                 market_infos: List[MarketTradingPairTuple],
                 order_type: str = "limit",
                 order_price: Optional[float] = None,
                 floor_price: Optional[float] = None,
                 cancel_order_wait_time: Optional[float] = 60.0,
                 is_buy: bool = True,
                 time_delay: float = 10.0,
                 num_individual_orders: int = 1,
                 order_amount: Decimal = Decimal("1.0"),
                 trading_time_duration: float = 0.0,
                 logging_options: int = OPTION_LOG_ALL,
                 status_report_interval: float = 900,
                 adjust_order_size: bool = False,
                 updated_order_size: float = 10.0,
                 order_size_spread: Decimal = s_decimal_zero,
                 bid_spread: Decimal = s_decimal_zero,
                 ask_spread: Decimal = s_decimal_zero,
                 order_levels: int = 1,
                 order_refresh_time: float = 30.0,
                 order_level_spread: Decimal = s_decimal_zero,
                 order_level_amount: Decimal = s_decimal_zero,
                 order_refresh_tolerance_pct: Decimal = s_decimal_neg_one,
                 filled_order_delay: float = 60.0,
                 inventory_skew_enabled: bool = False,
                 inventory_target_base_pct: Decimal = s_decimal_zero,
                 inventory_range_multiplier: Decimal = s_decimal_zero,
                 hanging_orders_enabled: bool = False,
                 hanging_orders_cancel_pct: Decimal = Decimal("0.1"),
                 asset_price_delegate: AssetPriceDelegate = None,
                 hb_app_notification: bool = False,
                 order_override: Dict[str, List[str]] = {}):
        """
        :param market_infos: list of market trading pairs
        :param order_type: type of order to place
        :param order_price: price to place the order at
        :param cancel_order_wait_time: how long to wait before cancelling an order
        :param is_buy: if the order is to buy
        :param time_delay: how long to wait between placing trades
        :param num_individual_orders: how many individual orders to split the order into
        :param order_amount: qty of the order to place
        :param logging_options: select the types of logs to output
        :param status_report_interval: how often to report network connection related warnings, if any
        :param adjust_order_size: change order size based on spread of order book
        :param updated_order_size: allow updates to order size lots dynamically
        :param order_size_spread: how wide to randomize the order sizes
        """

        if len(market_infos) < 1:
            raise ValueError(f"market_infos must not be empty.")

        super().__init__()
        self._market_infos = {
            (market_info.market, market_info.trading_pair): market_info
            for market_info in market_infos
        }
        self._market_info = market_infos[0]
        self._all_markets_ready = False
        self._place_orders = True
        self._logging_options = logging_options
        self._status_report_interval = status_report_interval
        self._time_delay = time_delay
        self._num_individual_orders = num_individual_orders
        self._quantity_remaining = order_amount
        self._time_to_cancel = {}
        self._order_type = order_type
        self._is_buy = is_buy
        self._should_stop_trading = False
        self._order_amount = order_amount
        self._first_order = True
        self._trading_time_duration_secs = trading_time_duration * 3600

        self._adjust_order_size = adjust_order_size
        self._updated_order_size = updated_order_size
        self._order_size_spread = order_size_spread
        self._bid_spread = bid_spread
        self._ask_spread = ask_spread
        self._order_levels = order_levels
        self._buy_levels = order_levels
        self._sell_levels = order_levels
        self._order_level_spread = order_level_spread
        self._order_level_amount = order_level_amount
        self._order_refresh_time = order_refresh_time
        self._order_refresh_tolerance_pct = order_refresh_tolerance_pct
        self._filled_order_delay = filled_order_delay
        self._inventory_skew_enabled = inventory_skew_enabled
        self._inventory_target_base_pct = inventory_target_base_pct
        self._inventory_range_multiplier = inventory_range_multiplier
        self._hanging_orders_enabled = hanging_orders_enabled
        self._hanging_orders_cancel_pct = hanging_orders_cancel_pct
        self._asset_price_delegate = asset_price_delegate
        self._order_override = order_override
        self._hb_app_notification = hb_app_notification

        if order_price is not None:
            self._order_price = order_price
        if floor_price is not None:
            self._floor_price = floor_price
        if cancel_order_wait_time is not None:
            self._cancel_order_wait_time = cancel_order_wait_time

        cdef:
            set all_markets = set([market_info.market for market_info in market_infos])

        self.c_add_markets(list(all_markets))

# begin - properties for script

    def all_markets_ready(self):
        return all([market.ready for market in self._sb_markets])

    @property
    def market_info(self) -> MarketTradingPairTuple:
        return self._market_info

    @property
    def trading_pair(self):
        return self._market_info.trading_pair

    @property
    def order_override(self):
        return self._order_override

    @order_override.setter
    def order_override(self, value: Dict[str, List[str]]):
        self._order_override = value

    @property
    def should_stop_trading(self):
        return self._should_stop_trading

    @should_stop_trading.setter
    def should_stop_trading(self, value: bool):
        self._should_stop_trading = value

    @property
    def adjust_order_size(self):
        return self._adjust_order_size

    @adjust_order_size.setter
    def adjust_order_size(self, value: bool):
        self._adjust_order_size = value

    @property
    def order_refresh_tolerance_pct(self) -> Decimal:
        return self._order_refresh_tolerance_pct

    @order_refresh_tolerance_pct.setter
    def order_refresh_tolerance_pct(self, value: Decimal):
        self._order_refresh_tolerance_pct = value

    @property
    def order_amount(self) -> Decimal:
        return self._order_amount

    @order_amount.setter
    def order_amount(self, value: Decimal):
        self._order_amount = value

    @property
    def order_levels(self) -> int:
        return self._order_levels

    @order_levels.setter
    def order_levels(self, value: int):
        self._order_levels = value
        self._buy_levels = value
        self._sell_levels = value

    @property
    def buy_levels(self) -> int:
        return self._buy_levels

    @buy_levels.setter
    def buy_levels(self, value: int):
        self._buy_levels = value

    @property
    def sell_levels(self) -> int:
        return self._sell_levels

    @sell_levels.setter
    def sell_levels(self, value: int):
        self._sell_levels = value

    @property
    def order_level_amount(self) -> Decimal:
        return self._order_level_amount

    @order_level_amount.setter
    def order_level_amount(self, value: Decimal):
        self._order_level_amount = value

    @property
    def order_level_spread(self) -> Decimal:
        return self._order_level_spread

    @order_level_spread.setter
    def order_level_spread(self, value: Decimal):
        self._order_level_spread = value

    @property
    def inventory_skew_enabled(self) -> bool:
        return self._inventory_skew_enabled

    @inventory_skew_enabled.setter
    def inventory_skew_enabled(self, value: bool):
        self._inventory_skew_enabled = value

    @property
    def inventory_target_base_pct(self) -> Decimal:
        return self._inventory_target_base_pct

    @inventory_target_base_pct.setter
    def inventory_target_base_pct(self, value: Decimal):
        self._inventory_target_base_pct = value

    @property
    def inventory_range_multiplier(self) -> Decimal:
        return self._inventory_range_multiplier

    @inventory_range_multiplier.setter
    def inventory_range_multiplier(self, value: Decimal):
        self._inventory_range_multiplier = value

    @property
    def hanging_orders_enabled(self) -> bool:
        return self._hanging_orders_enabled

    @hanging_orders_enabled.setter
    def hanging_orders_enabled(self, value: bool):
        self._hanging_orders_enabled = value

    @property
    def hanging_orders_cancel_pct(self) -> Decimal:
        return self._hanging_orders_cancel_pct

    @hanging_orders_cancel_pct.setter
    def hanging_orders_cancel_pct(self, value: Decimal):
        self._hanging_orders_cancel_pct = value

    @property
    def bid_spread(self) -> Decimal:
        return self._bid_spread

    @bid_spread.setter
    def bid_spread(self, value: Decimal):
        self._bid_spread = value

    @property
    def ask_spread(self) -> Decimal:
        return self._ask_spread

    @ask_spread.setter
    def ask_spread(self, value: Decimal):
        self._ask_spread = value

    @property
    def order_optimization_enabled(self) -> bool:
        return self._order_optimization_enabled

    @order_optimization_enabled.setter
    def order_optimization_enabled(self, value: bool):
        self._order_optimization_enabled = value

    @property
    def order_refresh_time(self) -> float:
        return self._order_refresh_time

    @order_refresh_time.setter
    def order_refresh_time(self, value: float):
        self._order_refresh_time = value

    @property
    def filled_order_delay(self) -> float:
        return self._filled_order_delay

    @filled_order_delay.setter
    def filled_order_delay(self, value: float):
        self._filled_order_delay = value

    @property
    def filled_order_delay(self) -> float:
        return self._filled_order_delay

    @filled_order_delay.setter
    def filled_order_delay(self, value: float):
        self._filled_order_delay = value

    def get_mid_price(self) -> float:
        return self.c_get_mid_price()

    cdef object c_get_mid_price(self):
        cdef:
            AssetPriceDelegate delegate = self._asset_price_delegate
            object mid_price
        if self._asset_price_delegate is not None:
            mid_price = delegate.c_get_mid_price()
        else:
            mid_price = self._market_info.get_mid_price()
        return mid_price

# end - properties for script

    @property
    def active_bids(self) -> List[Tuple[ExchangeBase, LimitOrder]]:
        return self._sb_order_tracker.active_bids

    @property
    def active_asks(self) -> List[Tuple[ExchangeBase, LimitOrder]]:
        return self._sb_order_tracker.active_asks

    @property
    def active_limit_orders(self) -> List[Tuple[ExchangeBase, LimitOrder]]:
        return self._sb_order_tracker.active_limit_orders

    @property
    def in_flight_cancels(self) -> Dict[str, float]:
        return self._sb_order_tracker.in_flight_cancels

    @property
    def market_info_to_active_orders(self) -> Dict[MarketTradingPairTuple, List[LimitOrder]]:
        return self._sb_order_tracker.market_pair_to_active_orders

    @property
    def logging_options(self) -> int:
        return self._logging_options

    @logging_options.setter
    def logging_options(self, int64_t logging_options):
        self._logging_options = logging_options

    @property
    def place_orders(self):
        return self._place_orders

    def format_status(self) -> str:
        cdef:
            list lines = []
            list warning_lines = []
            dict market_info_to_active_orders = self.market_info_to_active_orders
            list active_orders = []

        for market_info in self._market_infos.values():
            active_orders = self.market_info_to_active_orders.get(market_info, [])

            warning_lines.extend(self.network_warning([market_info]))

            markets_df = self.market_status_data_frame([market_info])
            lines.extend(["", "  Markets:"] + ["    " + line for line in str(markets_df).split("\n")])

            assets_df = self.wallet_balance_data_frame([market_info])
            lines.extend(["", "  Assets:"] + ["    " + line for line in str(assets_df).split("\n")])

            # See if there're any open orders.
            if len(active_orders) > 0:
                df = LimitOrder.to_pandas(active_orders)
                df_lines = str(df).split("\n")
                lines.extend(["", "  Active orders:"] +
                             ["    " + line for line in df_lines])
            else:
                lines.extend(["", "  No active maker orders."])

            warning_lines.extend(self.balance_warning([market_info]))

        if len(warning_lines) > 0:
            lines.extend(["", "*** WARNINGS ***"] + warning_lines)

        return "\n".join(lines)

    def stop_hb_app(self):
        if self._hb_app_notification:
            from hummingbot.client.hummingbot_application import HummingbotApplication
            HummingbotApplication.main_application()._handle_command("stop")

    cdef c_did_fill_order(self, object order_filled_event):
        """
        Output log for filled order.

        :param order_filled_event: Order filled event
        """
        cdef:
            str order_id = order_filled_event.order_id
            object market_info = self._sb_order_tracker.c_get_shadow_market_pair_from_order_id(order_id)
            tuple order_fill_record

        if market_info is not None:
            limit_order_record = self._sb_order_tracker.c_get_shadow_limit_order(order_id)
            order_fill_record = (limit_order_record, order_filled_event)

            if order_filled_event.trade_type is TradeType.BUY:
                if self._logging_options & self.OPTION_LOG_MAKER_ORDER_FILLED:
                    self.log_with_clock(
                        logging.INFO,
                        f"({market_info.trading_pair}) Limit buy order of "
                        f"{order_filled_event.amount} {market_info.base_asset} filled."
                    )
            else:
                if self._logging_options & self.OPTION_LOG_MAKER_ORDER_FILLED:
                    self.log_with_clock(
                        logging.INFO,
                        f"({market_info.trading_pair}) Limit sell order of "
                        f"{order_filled_event.amount} {market_info.base_asset} filled."
                    )

    cdef c_did_complete_buy_order(self, object order_completed_event):
        """
        Output log for completed buy order.

        :param order_completed_event: Order completed event
        """
        cdef:
            str order_id = order_completed_event.order_id
            object market_info = self._sb_order_tracker.c_get_market_pair_from_order_id(order_id)
            LimitOrder limit_order_record

        if market_info is not None:
            limit_order_record = self._sb_order_tracker.c_get_limit_order(market_info, order_id)
            # If its not market order
            if limit_order_record is not None:
                self.log_with_clock(
                    logging.INFO,
                    f"({market_info.trading_pair}) Limit buy order {order_id} "
                    f"({limit_order_record.quantity} {limit_order_record.base_currency} @ "
                    f"{limit_order_record.price} {limit_order_record.quote_currency}) has been filled."
                )
            else:
                market_order_record = self._sb_order_tracker.c_get_market_order(market_info, order_id)
                self.log_with_clock(
                    logging.INFO,
                    f"({market_info.trading_pair}) Market buy order {order_id} "
                    f"({market_order_record.amount} {market_order_record.base_asset}) has been filled."
                )

    cdef c_did_complete_sell_order(self, object order_completed_event):
        """
        Output log for completed sell order.

        :param order_completed_event: Order completed event
        """
        cdef:
            str order_id = order_completed_event.order_id
            object market_info = self._sb_order_tracker.c_get_market_pair_from_order_id(order_id)
            LimitOrder limit_order_record

        if market_info is not None:
            limit_order_record = self._sb_order_tracker.c_get_limit_order(market_info, order_id)
            # If its not market order
            if limit_order_record is not None:
                self.log_with_clock(
                    logging.INFO,
                    f"({market_info.trading_pair}) Limit sell order {order_id} "
                    f"({limit_order_record.quantity} {limit_order_record.base_currency} @ "
                    f"{limit_order_record.price} {limit_order_record.quote_currency}) has been filled."
                )
            else:
                market_order_record = self._sb_order_tracker.c_get_market_order(market_info, order_id)
                self.log_with_clock(
                    logging.INFO,
                    f"({market_info.trading_pair}) Market sell order {order_id} "
                    f"({market_order_record.amount} {market_order_record.base_asset}) has been filled."
                )

    cdef c_start(self, Clock clock, double timestamp):
        self._trading_start_time = timestamp
        StrategyBase.c_start(self, clock, timestamp)
        self.logger().info(f"Waiting for {self._time_delay} to place orders")
        self._previous_timestamp = timestamp
        self._last_timestamp = timestamp

    cdef c_tick(self, double timestamp):
        """
        Clock tick entry point.

        For the TWAP strategy, this function simply checks for the readiness and connection status of markets, and
        then delegates the processing of each market info to c_process_market().

        :param timestamp: current tick timestamp
        """
        StrategyBase.c_tick(self, timestamp)
        cdef:
            int64_t current_tick = <int64_t>(timestamp // self._status_report_interval)
            int64_t last_tick = <int64_t>(self._last_timestamp // self._status_report_interval)
            bint should_report_warnings = ((current_tick > last_tick) and
                                           (self._logging_options & self.OPTION_LOG_STATUS_REPORT))
            list active_maker_orders = self.active_limit_orders

        try:
            if not self._all_markets_ready:
                self._all_markets_ready = all([market.ready for market in self._sb_markets])
                if not self._all_markets_ready:
                    # Markets not ready yet. Don't do anything.
                    if should_report_warnings:
                        self.logger().warning(f"Markets are not ready. No market making trades are permitted.")
                    return

            if should_report_warnings:
                if not all([market.network_status is NetworkStatus.CONNECTED for market in self._sb_markets]):
                    self.logger().warning(f"WARNING: Some markets are not connected or are down at the moment. Market "
                                          f"making may be dangerous when markets or networks are unstable.")

            for market_info in self._market_infos.values():
                self.c_process_market(market_info)
        finally:
            self._last_timestamp = timestamp

    cdef c_get_order_sizes_from_order_book(self, num_entries):
        cdef:
            OrderBook order_book = self.market_info.order_book
        orders = []
        count = 0
        if self._is_buy:  # buy
            for entry in order_book.bid_entries():
                orders.append(entry.amount); count += 1
                if count == num_entries:
                    break
        else:  # sell
            for entry in order_book.ask_entries():
                orders.append(entry.amount); count += 1
                if count == num_entries:
                    break
        orders = [order for order in orders if order <= self._order_amount]
        self.logger().info(f"Order sizes right now: {orders}")
        min_chunk_size = min(orders)
        max_chunk_size = max(orders)
        self.logger().info(f"Order size range: {min_chunk_size},{max_chunk_size}")
        return (min_chunk_size, max_chunk_size)

    cdef c_place_orders(self, object market_info):
        """
        Places an individual order specified by the user input if the user has enough balance and if the order quantity
        can be broken up to the number of desired orders

        :param market_info: a market trading pair
        """
        cdef:
            ExchangeBase market = market_info.market
            order_amount_size = min((self._order_amount / self._num_individual_orders), self._quantity_remaining)
            object quantized_amount = market.c_quantize_order_amount(market_info.trading_pair, Decimal(order_amount_size))
            object quantized_price = market.c_quantize_order_price(market_info.trading_pair, Decimal(self._order_price))

        self.logger().info(f"Checking to see if the incremental order size is possible")
        self.logger().info(f"Checking to see if the user has enough balance to place orders")
        if self._adjust_order_size and self._updated_order_size > 0.0:
            quantized_amount = Decimal(min(self._updated_order_size, self._quantity_remaining))
            self.logger().info(f"Adjusting your order size to a new lot size :=> {quantized_amount}")
        else:
            self.logger().info(f"Default order size :=> {quantized_amount}")

        if self._order_size_spread != 0:
            # calculate the wide band around the target order size
            high = quantized_amount + (quantized_amount * self._order_size_spread)
            low = quantized_amount - (quantized_amount * self._order_size_spread)
            r = float(rand()/RAND_MAX)
            new_quantized_amount = round(float(high - low) * r + float(low))
            self.logger().info(f"Randomized the order size in this range ({low}, {high}) :=> {new_quantized_amount}")
            quantized_amount = Decimal(min(new_quantized_amount, self._quantity_remaining))

        if quantized_amount != 0:
            if self.c_has_enough_balance(market_info):

                if self._order_type == "market":
                    if self._is_buy:
                        ask_price = market.get_price(market_info.trading_pair, True)
                        self.logger().info(f"Current ASK price => {ask_price}")
                        order_id = self.c_buy_with_specific_market(market_info,
                                                                   amount = quantized_amount,
                                                                   order_type = OrderType.LIMIT,
                                                                   price = Decimal(ask_price))
                        self.logger().info("Market buy order has been executed")
                    else:
                        bid_price = market.get_price(market_info.trading_pair, False)
                        self.logger().info(f"Current BID price => {bid_price}")
                        if self._floor_price is not None:
                            if bid_price < self._floor_price:
                                self.logger().warning(f"Cannot trade below floor price: {bid_price} < {self._floor_price}")
                                return

                        order_id = self.c_sell_with_specific_market(market_info,
                                                                    amount = quantized_amount,
                                                                    order_type = OrderType.LIMIT,
                                                                    price = Decimal(bid_price))
                        self.logger().info("Market sell order has been executed")
                else:
                    if self._is_buy:
                        order_id = self.c_buy_with_specific_market(market_info,
                                                                   amount = quantized_amount,
                                                                   order_type = OrderType.LIMIT,
                                                                   price = quantized_price)
                        self.logger().info("Limit buy order has been placed")

                    else:
                        order_id = self.c_sell_with_specific_market(market_info,
                                                                    amount = quantized_amount,
                                                                    order_type = OrderType.LIMIT,
                                                                    price = quantized_price)
                        self.logger().info("Limit sell order has been placed")
                    self._time_to_cancel[order_id] = self._current_timestamp + self._cancel_order_wait_time

                self._quantity_remaining = Decimal(self._quantity_remaining) - quantized_amount

            else:
                self.logger().info(f"Not enough balance to run the strategy. Please check balances and try again.")
        else:
            self.logger().warning(f"Not possible to break the order into the desired number of segments.")

    cdef c_has_enough_balance(self, object market_info):
        """
        Checks to make sure the user has the sufficient balance in order to place the specified order

        :param market_info: a market trading pair
        :return: True if user has enough balance, False if not
        """
        cdef:
            ExchangeBase market = market_info.market
            double base_asset_balance = market.c_get_balance(market_info.base_asset)
            double quote_asset_balance = market.c_get_balance(market_info.quote_asset)
            OrderBook order_book = market_info.order_book
            double price = order_book.c_get_price_for_volume(True, float(self._quantity_remaining)).result_price

        return quote_asset_balance >= float(self._quantity_remaining) * price if self._is_buy else base_asset_balance >= float(self._quantity_remaining)

    cdef c_process_market(self, object market_info):
        """
        Checks if enough time has elapsed from previous order to place order and if so, calls c_place_orders() and
        cancels orders if they are older than self._cancel_order_wait_time.

        :param market_info: a market trading pair
        """
        cdef:
            ExchangeBase maker_market = market_info.market
            set cancel_order_ids = set()

        # check if the current time is greater than trading time duration
        _trading_stop_time = self._current_timestamp - self._trading_start_time
        if (_trading_stop_time > self._trading_time_duration_secs) and not self._first_order:
            self.logger().info(f"Start time: "
                               f"{datetime.fromtimestamp(self._trading_start_time).strftime('%Y-%m-%d %H:%M:%S')} ")
            self.logger().info(f"Time to stop trading. Bot has been trading for over {self._trading_time_duration_secs / 3600} hours")
            # initiate stop command to hb
            self.stop_hb_app()
            return

        elif self._quantity_remaining > 0:

            # If stop condition reached, do not place any new orders
            if self._should_stop_trading:
                self.logger().info(f"Stop condition triggered. Will not place any new orders.")
                # initiate stop command to hb
                self.stop_hb_app()

            # If current timestamp is greater than the start timestamp and its the first order
            elif (self._current_timestamp > self._previous_timestamp) and (self._first_order):

                self.logger().info(f"Trying to place orders now. ")
                self._previous_timestamp = self._current_timestamp
                self.c_place_orders(market_info)
                self._first_order = False

            # If current timestamp is greater than the start timestamp + time delay place orders
            elif (self._current_timestamp > self._previous_timestamp + self._time_delay) and (self._first_order is False):

                self.logger().info(f"Current time: "
                                   f"{datetime.fromtimestamp(self._current_timestamp).strftime('%Y-%m-%d %H:%M:%S')} "
                                   f"is now greater than "
                                   f"Previous time: "
                                   f"{datetime.fromtimestamp(self._previous_timestamp).strftime('%Y-%m-%d %H:%M:%S')} "
                                   f" with time delay: {self._time_delay}. Trying to place orders now. ")
                self._previous_timestamp = self._current_timestamp
                self.c_place_orders(market_info)

        active_orders = self.market_info_to_active_orders.get(market_info, [])

        if len(active_orders) > 0:
            for active_order in active_orders:
                if active_order.client_order_id not in self._time_to_cancel.keys():
                    continue
                if self._current_timestamp >= self._time_to_cancel[active_order.client_order_id]:
                    cancel_order_ids.add(active_order.client_order_id)

        if len(cancel_order_ids) > 0:

            for order in cancel_order_ids:
                self.c_cancel_order(market_info, order)

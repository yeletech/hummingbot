from typing import (
    List,
    Tuple,
)

from hummingbot.strategy.market_trading_pair_tuple import MarketTradingPairTuple
from hummingbot.strategy.dyn_twap_trade import (
    TwapTradeStrategy
)
from hummingbot.strategy.dyn_twap_trade.dyn_twap_trade_config_map import dyn_twap_trade_config_map
from decimal import Decimal


def start(self):
    try:
        order_amount = dyn_twap_trade_config_map.get("order_amount").value
        order_type = dyn_twap_trade_config_map.get("order_type").value
        is_buy = dyn_twap_trade_config_map.get("is_buy").value
        time_delay = dyn_twap_trade_config_map.get("time_delay").value
        num_individual_orders = dyn_twap_trade_config_map.get("num_individual_orders").value
        market = dyn_twap_trade_config_map.get("market").value.lower()
        raw_market_trading_pair = dyn_twap_trade_config_map.get("market_trading_pair_tuple").value
        trading_time_duration = dyn_twap_trade_config_map.get("trading_time_duration").value
        adjust_order_size = dyn_twap_trade_config_map.get("adjust_order_size").value
        updated_order_size = dyn_twap_trade_config_map.get("updated_order_size").value
        order_size_spread = dyn_twap_trade_config_map.get("order_size_spread").value / Decimal('100')
        floor_price = None
        order_price = None
        cancel_order_wait_time = None

        if order_type == "limit":
            order_price = dyn_twap_trade_config_map.get("order_price").value
            floor_price = dyn_twap_trade_config_map.get("floor_price").value
            cancel_order_wait_time = dyn_twap_trade_config_map.get("cancel_order_wait_time").value
            # TODO: check that the floor price is less than order price (if set)
            if order_price is not None and floor_price is not None:
                if order_price < floor_price:
                    self._notify(f"order price ({order_price}) should be higher than the floor price ({floor_price})")
        else:
            _floor_price = dyn_twap_trade_config_map.get("floor_price").value
            if type(_floor_price) is float:
                floor_price = _floor_price

        try:
            assets: Tuple[str, str] = self._initialize_market_assets(market, [raw_market_trading_pair])[0]
        except ValueError as e:
            self._notify(str(e))
            return

        market_names: List[Tuple[str, List[str]]] = [(market, [raw_market_trading_pair])]

        self._initialize_wallet(token_trading_pairs=list(set(assets)))
        self._initialize_markets(market_names)
        self.assets = set(assets)

        maker_data = [self.markets[market], raw_market_trading_pair] + list(assets)
        self.market_trading_pair_tuples = [MarketTradingPairTuple(*maker_data)]

        strategy_logging_options = TwapTradeStrategy.OPTION_LOG_ALL

        self.strategy = TwapTradeStrategy(market_infos=[MarketTradingPairTuple(*maker_data)],
                                          order_type=order_type,
                                          order_price=order_price,
                                          floor_price=floor_price,
                                          cancel_order_wait_time=cancel_order_wait_time,
                                          is_buy=is_buy,
                                          time_delay=time_delay,
                                          num_individual_orders = num_individual_orders,
                                          order_amount=order_amount,
                                          trading_time_duration=trading_time_duration,
                                          hb_app_notification=True,
                                          logging_options=strategy_logging_options,
                                          adjust_order_size=adjust_order_size,
                                          updated_order_size=updated_order_size,
                                          order_size_spread=order_size_spread)
    except Exception as e:
        self._notify(str(e))
        self.logger().error("Unknown error during initialization.", exc_info=True)

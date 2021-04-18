from hummingbot.client.config.config_var import ConfigVar
from hummingbot.client.config.config_validators import (
    validate_exchange,
    validate_market_trading_pair,
    validate_decimal,
)


from hummingbot.client.settings import (
    required_exchanges,
    EXAMPLE_PAIRS,
)
from typing import Optional


def trading_pair_prompt():
    market = dyn_twap_trade_config_map.get("market").value
    example = EXAMPLE_PAIRS.get(market)
    return "Enter the token trading pair you would like to trade on %s%s >>> " \
           % (market, f" (e.g. {example})" if example else "")


def str2bool(value: str):
    return str(value).lower() in ("yes", "true", "t", "1")


# checks if the trading pair is valid
def validate_market_trading_pair_tuple(value: str) -> Optional[str]:
    market = dyn_twap_trade_config_map.get("market").value
    return validate_market_trading_pair(market, value)


dyn_twap_trade_config_map = {
    "strategy":
        ConfigVar(key="strategy",
                  prompt="",
                  default="twap_trade"),
    "market":
        ConfigVar(key="market",
                  prompt="Enter the name of the exchange >>> ",
                  validator=validate_exchange,
                  on_validated=lambda value: required_exchanges.append(value), prompt_on_new=True),
    "market_trading_pair_tuple":
        ConfigVar(key="market_trading_pair_tuple",
                  prompt=trading_pair_prompt,
                  validator=validate_market_trading_pair_tuple, prompt_on_new=True),
    "order_type":
        ConfigVar(key="order_type",
                  prompt="Enter type of order (limit/market) default is market >>> ",
                  type_str="str",
                  validator=lambda v: None if v in {"limit", "market", ""} else "Invalid order type.",
                  default="market", prompt_on_new=True),
    "order_amount":
        ConfigVar(key="order_amount",
                  prompt="What is your preferred quantity (denominated in the base asset, default is 1)? "
                         ">>> ",
                  default=1.0,
                  type_str="float", prompt_on_new=True),
    "is_buy":
        ConfigVar(key="is_buy",
                  prompt="Enter True for Buy order and False for Sell order (default is Buy Order) >>> ",
                  type_str="bool",
                  default=True, prompt_on_new=True),
    "num_individual_orders":
        ConfigVar(key="num_individual_orders",
                  prompt="Into how many individual orders do you want to split this order? (Enter 10 to indicate 10 individual orders. "
                         "Default is 1)? >>> ",
                  type_str="float",
                  default=1, prompt_on_new=True),
    "time_delay":
        ConfigVar(key="time_delay",
                  prompt="How many seconds do you want to wait between each individual order? (Enter 10 to indicate 10 seconds. "
                         "Default is 10)? >>> ",
                  type_str="float",
                  default=10, prompt_on_new=True),
    "order_price":
        ConfigVar(key="order_price",
                  prompt="What is the price of the limit order ? >>> ",
                  required_if=lambda: dyn_twap_trade_config_map.get("order_type").value == "limit",
                  type_str="float", prompt_on_new=True),
    "cancel_order_wait_time":
        ConfigVar(key="cancel_order_wait_time",
                  prompt="How long do you want to wait before cancelling your limit order (in seconds). "
                         "(Default is 60 seconds) ? >>> ",
                  required_if=lambda: dyn_twap_trade_config_map.get("order_type").value == "limit",
                  type_str="float",
                  default=60),
    "trading_time_duration":
        ConfigVar(key="trading_time_duration",
                  prompt="How many hours do you want to run the trade with the bot? "
                         "(Default is 24 hours)? >>> ",
                  type_str="float",
                  default=24, prompt_on_new=True),
    "adjust_order_size":
        ConfigVar(key="adjust_order_size",
                  prompt="Enter True to dynamically adjust the order sizes for each trade (default is False) >>> ",
                  type_str="bool",
                  default=False, prompt_on_new=True),
    "updated_order_size":
        ConfigVar(key="updated_order_size",
                  prompt="New order size to adjust to (default is 10)? >>> ",
                  required_if=lambda: dyn_twap_trade_config_map.get("adjust_order_size").value is True,
                  type_str="float", default=10, prompt_on_new=True),
    "order_size_spread":
        ConfigVar(key="order_size_spread",
                  prompt="How wide do you want to randomize the order size"
                         "? (Enter 1 to indicate 1%) >>> ",
                  type_str="decimal",
                  validator=lambda v: validate_decimal(v, 0, 100, inclusive=True),
                  prompt_on_new=True),
    "floor_price":
        ConfigVar(key="floor_price",
                  prompt="What is the floor price of your limit order ? >>> ",
                  required_if=lambda: dyn_twap_trade_config_map.get("order_type").value == "limit",
                  type_str="float", prompt_on_new=True),
}

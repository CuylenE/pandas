"""
_Timestamp is a c-defined subclass of datetime.datetime

_Timestamp is PITA. Because we inherit from datetime, which has very specific
construction requirements, we need to do object instantiation in python
(see Timestamp class below). This will serve as a C extension type that
shadows the python class, where we do any heavy lifting.
"""
import warnings

import numpy as np
cimport numpy as cnp
from numpy cimport int64_t, int8_t, uint8_t, ndarray
cnp.import_array()

from cpython.object cimport (PyObject_RichCompareBool, PyObject_RichCompare,
                             Py_GT, Py_GE, Py_EQ, Py_NE, Py_LT, Py_LE)

from cpython.datetime cimport (datetime, time, PyDateTime_Check, PyDelta_Check,
                               PyTZInfo_Check, PyDateTime_IMPORT)
PyDateTime_IMPORT

from pandas._libs.tslibs.util cimport (
    is_datetime64_object, is_float_object, is_integer_object,
    is_timedelta64_object, is_array,
)

from pandas._libs.tslibs.base cimport ABCTimedelta, ABCTimestamp

from pandas._libs.tslibs cimport ccalendar

from pandas._libs.tslibs.conversion import normalize_i8_timestamps
from pandas._libs.tslibs.conversion cimport (
    _TSObject, convert_to_tsobject,
    convert_datetime_to_tsobject)
from pandas._libs.tslibs.fields import get_start_end_field, get_date_name_field
from pandas._libs.tslibs.nattype cimport NPY_NAT, c_NaT as NaT
from pandas._libs.tslibs.np_datetime cimport (
    check_dts_bounds, npy_datetimestruct, dt64_to_dtstruct,
    cmp_scalar,
)
from pandas._libs.tslibs.np_datetime import OutOfBoundsDatetime
from pandas._libs.tslibs.offsets cimport to_offset, is_tick_object, is_offset_object
from pandas._libs.tslibs.timedeltas import Timedelta
from pandas._libs.tslibs.timezones cimport (
    is_utc, maybe_get_tz, treat_tz_as_pytz, utc_pytz as UTC,
    get_timezone, tz_compare,
)
from pandas._libs.tslibs.tzconversion cimport tz_convert_single
from pandas._libs.tslibs.tzconversion import tz_localize_to_utc

# ----------------------------------------------------------------------
# Constants
_zero_time = time(0, 0)
_no_input = object()

# ----------------------------------------------------------------------


cdef inline object create_timestamp_from_ts(int64_t value,
                                            npy_datetimestruct dts,
                                            object tz, object freq, bint fold):
    """ convenience routine to construct a Timestamp from its parts """
    cdef _Timestamp ts_base
    ts_base = _Timestamp.__new__(Timestamp, dts.year, dts.month,
                                 dts.day, dts.hour, dts.min,
                                 dts.sec, dts.us, tz, fold=fold)
    ts_base.value = value
    ts_base.freq = freq
    ts_base.nanosecond = dts.ps // 1000

    return ts_base


class RoundTo:
    """
    enumeration defining the available rounding modes

    Attributes
    ----------
    MINUS_INFTY
        round towards -∞, or floor [2]_
    PLUS_INFTY
        round towards +∞, or ceil [3]_
    NEAREST_HALF_EVEN
        round to nearest, tie-break half to even [6]_
    NEAREST_HALF_MINUS_INFTY
        round to nearest, tie-break half to -∞ [5]_
    NEAREST_HALF_PLUS_INFTY
        round to nearest, tie-break half to +∞ [4]_


    References
    ----------
    .. [1] "Rounding - Wikipedia"
           https://en.wikipedia.org/wiki/Rounding
    .. [2] "Rounding down"
           https://en.wikipedia.org/wiki/Rounding#Rounding_down
    .. [3] "Rounding up"
           https://en.wikipedia.org/wiki/Rounding#Rounding_up
    .. [4] "Round half up"
           https://en.wikipedia.org/wiki/Rounding#Round_half_up
    .. [5] "Round half down"
           https://en.wikipedia.org/wiki/Rounding#Round_half_down
    .. [6] "Round half to even"
           https://en.wikipedia.org/wiki/Rounding#Round_half_to_even
    """
    @property
    def MINUS_INFTY(self) -> int:
        return 0

    @property
    def PLUS_INFTY(self) -> int:
        return 1

    @property
    def NEAREST_HALF_EVEN(self) -> int:
        return 2

    @property
    def NEAREST_HALF_PLUS_INFTY(self) -> int:
        return 3

    @property
    def NEAREST_HALF_MINUS_INFTY(self) -> int:
        return 4


cdef inline _floor_int64(values, unit):
    return values - np.remainder(values, unit)

cdef inline _ceil_int64(values, unit):
    return values + np.remainder(-values, unit)

cdef inline _rounddown_int64(values, unit):
    return _ceil_int64(values - unit//2, unit)

cdef inline _roundup_int64(values, unit):
    return _floor_int64(values + unit//2, unit)


def round_nsint64(values, mode, freq):
    """
    Applies rounding mode at given frequency

    Parameters
    ----------
    values : :obj:`ndarray`
    mode : instance of `RoundTo` enumeration
    freq : str, obj

    Returns
    -------
    :obj:`ndarray`
    """

    unit = to_offset(freq).nanos

    if mode == RoundTo.MINUS_INFTY:
        return _floor_int64(values, unit)
    elif mode == RoundTo.PLUS_INFTY:
        return _ceil_int64(values, unit)
    elif mode == RoundTo.NEAREST_HALF_MINUS_INFTY:
        return _rounddown_int64(values, unit)
    elif mode == RoundTo.NEAREST_HALF_PLUS_INFTY:
        return _roundup_int64(values, unit)
    elif mode == RoundTo.NEAREST_HALF_EVEN:
        # for odd unit there is no need of a tie break
        if unit % 2:
            return _rounddown_int64(values, unit)
        quotient, remainder = np.divmod(values, unit)
        mask = np.logical_or(
            remainder > (unit // 2),
            np.logical_and(remainder == (unit // 2), quotient % 2)
        )
        quotient[mask] += 1
        return quotient * unit

    # if/elif above should catch all rounding modes defined in enum 'RoundTo':
    # if flow of control arrives here, it is a bug
    raise ValueError("round_nsint64 called with an unrecognized rounding mode")


# ----------------------------------------------------------------------

def integer_op_not_supported(obj):
    # GH#22535 add/sub of integers and int-arrays is no longer allowed
    # Note we return rather than raise the exception so we can raise in
    #  the caller; mypy finds this more palatable.
    cls = type(obj).__name__

    # GH#30886 using an fstring raises SystemError
    int_addsub_msg = (
        "Addition/subtraction of integers and integer-arrays with {cls} is "
        "no longer supported.  Instead of adding/subtracting `n`, "
        "use `n * obj.freq`"
    ).format(cls=cls)
    return TypeError(int_addsub_msg)


# ----------------------------------------------------------------------

cdef class _Timestamp(ABCTimestamp):

    # higher than np.ndarray and np.matrix
    __array_priority__ = 100

    def __hash__(_Timestamp self):
        if self.nanosecond:
            return hash(self.value)
        return datetime.__hash__(self)

    def __richcmp__(_Timestamp self, object other, int op):
        cdef:
            _Timestamp ots
            int ndim

        if isinstance(other, _Timestamp):
            ots = other
        elif other is NaT:
            return op == Py_NE
        elif PyDateTime_Check(other) or is_datetime64_object(other):
            if self.nanosecond == 0 and PyDateTime_Check(other):
                val = self.to_pydatetime()
                return PyObject_RichCompareBool(val, other, op)

            try:
                ots = type(self)(other)
            except ValueError:
                return self._compare_outside_nanorange(other, op)

        elif is_array(other):
            # avoid recursion error GH#15183
            if other.dtype.kind == "M":
                if self.tz is None:
                    return PyObject_RichCompare(self.asm8, other, op)
                raise TypeError(
                    "Cannot compare tz-naive and tz-aware timestamps"
                )
            elif other.dtype.kind == "O":
                # Operate element-wise
                return np.array(
                    [PyObject_RichCompare(self, x, op) for x in other],
                    dtype=bool,
                )
            elif op == Py_NE:
                return np.ones(other.shape, dtype=np.bool_)
            elif op == Py_EQ:
                return np.zeros(other.shape, dtype=np.bool_)
            return NotImplemented

        else:
            return NotImplemented

        self._assert_tzawareness_compat(ots)
        return cmp_scalar(self.value, ots.value, op)

    def __reduce_ex__(self, protocol):
        # python 3.6 compat
        # https://bugs.python.org/issue28730
        # now __reduce_ex__ is defined and higher priority than __reduce__
        return self.__reduce__()

    def __repr__(self) -> str:
        stamp = self._repr_base
        zone = None

        try:
            stamp += self.strftime('%z')
            if self.tzinfo:
                zone = get_timezone(self.tzinfo)
        except ValueError:
            year2000 = self.replace(year=2000)
            stamp += year2000.strftime('%z')
            if self.tzinfo:
                zone = get_timezone(self.tzinfo)

        try:
            stamp += zone.strftime(' %%Z')
        except AttributeError:
            # e.g. tzlocal has no `strftime`
            pass

        tz = f", tz='{zone}'" if zone is not None else ""
        freq = "" if self.freq is None else f", freq='{self.freqstr}'"

        return f"Timestamp('{stamp}'{tz}{freq})"

    cdef bint _compare_outside_nanorange(_Timestamp self, datetime other,
                                         int op) except -1:
        cdef:
            datetime dtval = self.to_pydatetime()

        self._assert_tzawareness_compat(other)
        return PyObject_RichCompareBool(dtval, other, op)

    cdef _assert_tzawareness_compat(_Timestamp self, datetime other):
        if self.tzinfo is None:
            if other.tzinfo is not None:
                raise TypeError('Cannot compare tz-naive and tz-aware '
                                'timestamps')
        elif other.tzinfo is None:
            raise TypeError('Cannot compare tz-naive and tz-aware timestamps')

    cpdef datetime to_pydatetime(_Timestamp self, bint warn=True):
        """
        Convert a Timestamp object to a native Python datetime object.

        If warn=True, issue a warning if nanoseconds is nonzero.
        """
        if self.nanosecond != 0 and warn:
            warnings.warn("Discarding nonzero nanoseconds in conversion",
                          UserWarning, stacklevel=2)

        return datetime(self.year, self.month, self.day,
                        self.hour, self.minute, self.second,
                        self.microsecond, self.tzinfo)

    cpdef to_datetime64(self):
        """
        Return a numpy.datetime64 object with 'ns' precision.
        """
        return np.datetime64(self.value, 'ns')

    def to_numpy(self, dtype=None, copy=False) -> np.datetime64:
        """
        Convert the Timestamp to a NumPy datetime64.

        .. versionadded:: 0.25.0

        This is an alias method for `Timestamp.to_datetime64()`. The dtype and
        copy parameters are available here only for compatibility. Their values
        will not affect the return value.

        Returns
        -------
        numpy.datetime64

        See Also
        --------
        DatetimeIndex.to_numpy : Similar method for DatetimeIndex.
        """
        return self.to_datetime64()

    def __add__(self, other):
        cdef:
            int64_t other_int, nanos = 0

        if is_timedelta64_object(other):
            other_int = other.astype('timedelta64[ns]').view('i8')
            return type(self)(self.value + other_int, tz=self.tzinfo, freq=self.freq)

        elif is_integer_object(other):
            raise integer_op_not_supported(self)

        elif PyDelta_Check(other):
            # logic copied from delta_to_nanoseconds to prevent circular import
            if isinstance(other, ABCTimedelta):
                # pd.Timedelta
                nanos = other.value
            else:
                nanos = (other.days * 24 * 60 * 60 * 1000000 +
                         other.seconds * 1000000 +
                         other.microseconds) * 1000

            result = type(self)(self.value + nanos, tz=self.tzinfo, freq=self.freq)
            return result

        elif is_tick_object(other):
            try:
                nanos = other.nanos
            except OverflowError as err:
                raise OverflowError(
                    f"the add operation between {other} and {self} will overflow"
                ) from err
            result = type(self)(self.value + nanos, tz=self.tzinfo, freq=self.freq)
            return result

        elif is_array(other):
            if other.dtype.kind in ['i', 'u']:
                raise integer_op_not_supported(self)
            if other.dtype.kind == "m":
                if self.tz is None:
                    return self.asm8 + other
                return np.asarray(
                    [self + other[n] for n in range(len(other))],
                    dtype=object,
                )

        elif not isinstance(self, _Timestamp):
            # cython semantics, args have been switched and this is __radd__
            return other.__add__(self)

        return NotImplemented

    def __sub__(self, other):

        if (is_timedelta64_object(other) or is_integer_object(other) or
                PyDelta_Check(other) or is_tick_object(other)):
            neg_other = -other
            return self + neg_other

        elif is_array(other):
            if other.dtype.kind in ['i', 'u']:
                raise integer_op_not_supported(self)
            if other.dtype.kind == "m":
                if self.tz is None:
                    return self.asm8 - other
                return np.asarray(
                    [self - other[n] for n in range(len(other))],
                    dtype=object,
                )
            return NotImplemented

        if other is NaT:
            return NaT

        # coerce if necessary if we are a Timestamp-like
        if (PyDateTime_Check(self)
                and (PyDateTime_Check(other) or is_datetime64_object(other))):
            # both_timestamps is to determine whether Timedelta(self - other)
            # should raise the OOB error, or fall back returning a timedelta.
            both_timestamps = (isinstance(other, _Timestamp) and
                               isinstance(self, _Timestamp))
            if isinstance(self, _Timestamp):
                other = type(self)(other)
            else:
                self = type(other)(self)

            # validate tz's
            if not tz_compare(self.tzinfo, other.tzinfo):
                raise TypeError("Timestamp subtraction must have the "
                                "same timezones or no timezones")

            # scalar Timestamp/datetime - Timestamp/datetime -> yields a
            # Timedelta
            from pandas._libs.tslibs.timedeltas import Timedelta
            try:
                return Timedelta(self.value - other.value)
            except (OverflowError, OutOfBoundsDatetime) as err:
                if isinstance(other, _Timestamp):
                    if both_timestamps:
                        raise OutOfBoundsDatetime(
                            "Result is too large for pandas.Timedelta. Convert inputs "
                            "to datetime.datetime with 'Timestamp.to_pydatetime()' "
                            "before subtracting."
                        ) from err
                # We get here in stata tests, fall back to stdlib datetime
                #  method and return stdlib timedelta object
                pass
        elif is_datetime64_object(self):
            # GH#28286 cython semantics for __rsub__, `other` is actually
            #  the Timestamp
            return type(other)(self) - other

        return NotImplemented

    cdef int64_t _maybe_convert_value_to_local(self):
        """Convert UTC i8 value to local i8 value if tz exists"""
        cdef:
            int64_t val
        val = self.value
        if self.tz is not None and not is_utc(self.tz):
            val = tz_convert_single(self.value, UTC, self.tz)
        return val

    cpdef bint _get_start_end_field(self, str field):
        cdef:
            int64_t val
            dict kwds
            ndarray[uint8_t, cast=True] out
            int month_kw

        freq = self.freq
        if freq:
            kwds = freq.kwds
            month_kw = kwds.get('startingMonth', kwds.get('month', 12))
            freqstr = self.freqstr
        else:
            month_kw = 12
            freqstr = None

        val = self._maybe_convert_value_to_local()
        out = get_start_end_field(np.array([val], dtype=np.int64),
                                  field, freqstr, month_kw)
        return out[0]

    cpdef _get_date_name_field(self, object field, object locale):
        cdef:
            int64_t val
            object[:] out

        val = self._maybe_convert_value_to_local()
        out = get_date_name_field(np.array([val], dtype=np.int64),
                                  field, locale=locale)
        return out[0]

    @property
    def _repr_base(self) -> str:
        return f"{self._date_repr} {self._time_repr}"

    @property
    def _date_repr(self) -> str:
        # Ideal here would be self.strftime("%Y-%m-%d"), but
        # the datetime strftime() methods require year >= 1900
        return f'{self.year}-{self.month:02d}-{self.day:02d}'

    @property
    def _time_repr(self) -> str:
        result = f'{self.hour:02d}:{self.minute:02d}:{self.second:02d}'

        if self.nanosecond != 0:
            result += f'.{self.nanosecond + 1000 * self.microsecond:09d}'
        elif self.microsecond != 0:
            result += f'.{self.microsecond:06d}'

        return result

    @property
    def _short_repr(self) -> str:
        # format a Timestamp with only _date_repr if possible
        # otherwise _repr_base
        if (self.hour == 0 and
                self.minute == 0 and
                self.second == 0 and
                self.microsecond == 0 and
                self.nanosecond == 0):
            return self._date_repr
        return self._repr_base

    @property
    def asm8(self) -> np.datetime64:
        """
        Return numpy datetime64 format in nanoseconds.
        """
        return np.datetime64(self.value, 'ns')

    def timestamp(self):
        """Return POSIX timestamp as float."""
        # GH 17329
        # Note: Naive timestamps will not match datetime.stdlib
        return round(self.value / 1e9, 6)


# ----------------------------------------------------------------------

# Python front end to C extension type _Timestamp
# This serves as the box for datetime64


class Timestamp(_Timestamp):
    """
    Pandas replacement for python datetime.datetime object.

    Timestamp is the pandas equivalent of python's Datetime
    and is interchangeable with it in most cases. It's the type used
    for the entries that make up a DatetimeIndex, and other timeseries
    oriented data structures in pandas.

    Parameters
    ----------
    ts_input : datetime-like, str, int, float
        Value to be converted to Timestamp.
    freq : str, DateOffset
        Offset which Timestamp will have.
    tz : str, pytz.timezone, dateutil.tz.tzfile or None
        Time zone for time which Timestamp will have.
    unit : str
        Unit used for conversion if ts_input is of type int or float. The
        valid values are 'D', 'h', 'm', 's', 'ms', 'us', and 'ns'. For
        example, 's' means seconds and 'ms' means milliseconds.
    year, month, day : int
    hour, minute, second, microsecond : int, optional, default 0
    nanosecond : int, optional, default 0
        .. versionadded:: 0.23.0
    tzinfo : datetime.tzinfo, optional, default None
    fold : {0, 1}, default None, keyword-only
        Due to daylight saving time, one wall clock time can occur twice
        when shifting from summer to winter time; fold describes whether the
        datetime-like corresponds  to the first (0) or the second time (1)
        the wall clock hits the ambiguous time

        .. versionadded:: 1.1.0

    Notes
    -----
    There are essentially three calling conventions for the constructor. The
    primary form accepts four parameters. They can be passed by position or
    keyword.

    The other two forms mimic the parameters from ``datetime.datetime``. They
    can be passed by either position or keyword, but not both mixed together.

    Examples
    --------
    Using the primary calling convention:

    This converts a datetime-like string

    >>> pd.Timestamp('2017-01-01T12')
    Timestamp('2017-01-01 12:00:00')

    This converts a float representing a Unix epoch in units of seconds

    >>> pd.Timestamp(1513393355.5, unit='s')
    Timestamp('2017-12-16 03:02:35.500000')

    This converts an int representing a Unix-epoch in units of seconds
    and for a particular timezone

    >>> pd.Timestamp(1513393355, unit='s', tz='US/Pacific')
    Timestamp('2017-12-15 19:02:35-0800', tz='US/Pacific')

    Using the other two forms that mimic the API for ``datetime.datetime``:

    >>> pd.Timestamp(2017, 1, 1, 12)
    Timestamp('2017-01-01 12:00:00')

    >>> pd.Timestamp(year=2017, month=1, day=1, hour=12)
    Timestamp('2017-01-01 12:00:00')
    """

    @classmethod
    def fromordinal(cls, ordinal, freq=None, tz=None):
        """
        Timestamp.fromordinal(ordinal, freq=None, tz=None)

        Passed an ordinal, translate and convert to a ts.
        Note: by definition there cannot be any tz info on the ordinal itself.

        Parameters
        ----------
        ordinal : int
            Date corresponding to a proleptic Gregorian ordinal.
        freq : str, DateOffset
            Offset to apply to the Timestamp.
        tz : str, pytz.timezone, dateutil.tz.tzfile or None
            Time zone for the Timestamp.
        """
        return cls(datetime.fromordinal(ordinal),
                   freq=freq, tz=tz)

    @classmethod
    def now(cls, tz=None):
        """
        Timestamp.now(tz=None)

        Return new Timestamp object representing current time local to
        tz.

        Parameters
        ----------
        tz : str or timezone object, default None
            Timezone to localize to.
        """
        if isinstance(tz, str):
            tz = maybe_get_tz(tz)
        return cls(datetime.now(tz))

    @classmethod
    def today(cls, tz=None):
        """
        Timestamp.today(cls, tz=None)

        Return the current time in the local timezone.  This differs
        from datetime.today() in that it can be localized to a
        passed timezone.

        Parameters
        ----------
        tz : str or timezone object, default None
            Timezone to localize to.
        """
        return cls.now(tz)

    @classmethod
    def utcnow(cls):
        """
        Timestamp.utcnow()

        Return a new Timestamp representing UTC day and time.
        """
        return cls.now(UTC)

    @classmethod
    def utcfromtimestamp(cls, ts):
        """
        Timestamp.utcfromtimestamp(ts)

        Construct a naive UTC datetime from a POSIX timestamp.
        """
        return cls(datetime.utcfromtimestamp(ts))

    @classmethod
    def fromtimestamp(cls, ts):
        """
        Timestamp.fromtimestamp(ts)

        timestamp[, tz] -> tz's local time from POSIX timestamp.
        """
        return cls(datetime.fromtimestamp(ts))

    # Issue 25016.
    @classmethod
    def strptime(cls, date_string, format):
        """
        Timestamp.strptime(string, format)

        Function is not implemented. Use pd.to_datetime().
        """
        raise NotImplementedError(
            "Timestamp.strptime() is not implemented. "
            "Use to_datetime() to parse date strings."
        )

    @classmethod
    def combine(cls, date, time):
        """
        Timestamp.combine(date, time)

        date, time -> datetime with same date and time fields.
        """
        return cls(datetime.combine(date, time))

    def __new__(
        cls,
        object ts_input=_no_input,
        object freq=None,
        tz=None,
        unit=None,
        year=None,
        month=None,
        day=None,
        hour=None,
        minute=None,
        second=None,
        microsecond=None,
        nanosecond=None,
        tzinfo=None,
        *,
        fold=None
    ):
        # The parameter list folds together legacy parameter names (the first
        # four) and positional and keyword parameter names from pydatetime.
        #
        # There are three calling forms:
        #
        # - In the legacy form, the first parameter, ts_input, is required
        #   and may be datetime-like, str, int, or float. The second
        #   parameter, offset, is optional and may be str or DateOffset.
        #
        # - ints in the first, second, and third arguments indicate
        #   pydatetime positional arguments. Only the first 8 arguments
        #   (standing in for year, month, day, hour, minute, second,
        #   microsecond, tzinfo) may be non-None. As a shortcut, we just
        #   check that the second argument is an int.
        #
        # - Nones for the first four (legacy) arguments indicate pydatetime
        #   keyword arguments. year, month, and day are required. As a
        #   shortcut, we just check that the first argument was not passed.
        #
        # Mixing pydatetime positional and keyword arguments is forbidden!

        cdef _TSObject ts

        _date_attributes = [year, month, day, hour, minute, second,
                            microsecond, nanosecond]

        if tzinfo is not None:
            if not PyTZInfo_Check(tzinfo):
                # tzinfo must be a datetime.tzinfo object, GH#17690
                raise TypeError(
                    f"tzinfo must be a datetime.tzinfo object, not {type(tzinfo)}"
                )
            elif tz is not None:
                raise ValueError('Can provide at most one of tz, tzinfo')

            # User passed tzinfo instead of tz; avoid silently ignoring
            tz, tzinfo = tzinfo, None

        # Allow fold only for unambiguous input
        if fold is not None:
            if fold not in [0, 1]:
                raise ValueError(
                    "Valid values for the fold argument are None, 0, or 1."
                )

            if (ts_input is not _no_input and not (
                    PyDateTime_Check(ts_input) and
                    getattr(ts_input, 'tzinfo', None) is None)):
                raise ValueError(
                    "Cannot pass fold with possibly unambiguous input: int, "
                    "float, numpy.datetime64, str, or timezone-aware "
                    "datetime-like. Pass naive datetime-like or build "
                    "Timestamp from components."
                )

            if tz is not None and treat_tz_as_pytz(tz):
                raise ValueError(
                    "pytz timezones do not support fold. Please use dateutil "
                    "timezones."
                )

            if hasattr(ts_input, 'fold'):
                ts_input = ts_input.replace(fold=fold)

        # GH 30543 if pd.Timestamp already passed, return it
        # check that only ts_input is passed
        # checking verbosely, because cython doesn't optimize
        # list comprehensions (as of cython 0.29.x)
        if (isinstance(ts_input, Timestamp) and freq is None and
                tz is None and unit is None and year is None and
                month is None and day is None and hour is None and
                minute is None and second is None and
                microsecond is None and nanosecond is None and
                tzinfo is None):
            return ts_input
        elif isinstance(ts_input, str):
            # User passed a date string to parse.
            # Check that the user didn't also pass a date attribute kwarg.
            if any(arg is not None for arg in _date_attributes):
                raise ValueError(
                    "Cannot pass a date attribute keyword "
                    "argument when passing a date string"
                )

        elif ts_input is _no_input:
            # GH 31200
            # When year, month or day is not given, we call the datetime
            # constructor to make sure we get the same error message
            # since Timestamp inherits datetime
            datetime_kwargs = {
                "hour": hour or 0,
                "minute": minute or 0,
                "second": second or 0,
                "microsecond": microsecond or 0,
                "fold": fold or 0
            }
            if year is not None:
                datetime_kwargs["year"] = year
            if month is not None:
                datetime_kwargs["month"] = month
            if day is not None:
                datetime_kwargs["day"] = day

            ts_input = datetime(**datetime_kwargs)

        elif is_integer_object(freq):
            # User passed positional arguments:
            # Timestamp(year, month, day[, hour[, minute[, second[,
            # microsecond[, nanosecond[, tzinfo]]]]]])
            ts_input = datetime(ts_input, freq, tz, unit or 0,
                                year or 0, month or 0, day or 0, fold=fold or 0)
            nanosecond = hour
            tz = minute
            freq = None

        if getattr(ts_input, 'tzinfo', None) is not None and tz is not None:
            raise ValueError("Cannot pass a datetime or Timestamp with tzinfo with "
                             "the tz parameter. Use tz_convert instead.")

        ts = convert_to_tsobject(ts_input, tz, unit, 0, 0, nanosecond or 0)

        if ts.value == NPY_NAT:
            return NaT

        if freq is None:
            # GH 22311: Try to extract the frequency of a given Timestamp input
            freq = getattr(ts_input, 'freq', None)
        elif not is_offset_object(freq):
            freq = to_offset(freq)

        return create_timestamp_from_ts(ts.value, ts.dts, ts.tzinfo, freq, ts.fold)

    def _round(self, freq, mode, ambiguous='raise', nonexistent='raise'):
        if self.tz is not None:
            value = self.tz_localize(None).value
        else:
            value = self.value

        value = np.array([value], dtype=np.int64)

        # Will only ever contain 1 element for timestamp
        r = round_nsint64(value, mode, freq)[0]
        result = Timestamp(r, unit='ns')
        if self.tz is not None:
            result = result.tz_localize(
                self.tz, ambiguous=ambiguous, nonexistent=nonexistent
            )
        return result

    def round(self, freq, ambiguous='raise', nonexistent='raise'):
        """
        Round the Timestamp to the specified resolution.

        Parameters
        ----------
        freq : str
            Frequency string indicating the rounding resolution.
        ambiguous : bool or {'raise', 'NaT'}, default 'raise'
            The behavior is as follows:

            * bool contains flags to determine if time is dst or not (note
              that this flag is only applicable for ambiguous fall dst dates).
            * 'NaT' will return NaT for an ambiguous time.
            * 'raise' will raise an AmbiguousTimeError for an ambiguous time.

            .. versionadded:: 0.24.0
        nonexistent : {'raise', 'shift_forward', 'shift_backward, 'NaT', \
timedelta}, default 'raise'
            A nonexistent time does not exist in a particular timezone
            where clocks moved forward due to DST.

            * 'shift_forward' will shift the nonexistent time forward to the
              closest existing time.
            * 'shift_backward' will shift the nonexistent time backward to the
              closest existing time.
            * 'NaT' will return NaT where there are nonexistent times.
            * timedelta objects will shift nonexistent times by the timedelta.
            * 'raise' will raise an NonExistentTimeError if there are
              nonexistent times.

            .. versionadded:: 0.24.0

        Returns
        -------
        a new Timestamp rounded to the given resolution of `freq`

        Raises
        ------
        ValueError if the freq cannot be converted
        """
        return self._round(
            freq, RoundTo.NEAREST_HALF_EVEN, ambiguous, nonexistent
        )

    def floor(self, freq, ambiguous='raise', nonexistent='raise'):
        """
        return a new Timestamp floored to this resolution.

        Parameters
        ----------
        freq : str
            Frequency string indicating the flooring resolution.
        ambiguous : bool or {'raise', 'NaT'}, default 'raise'
            The behavior is as follows:

            * bool contains flags to determine if time is dst or not (note
              that this flag is only applicable for ambiguous fall dst dates).
            * 'NaT' will return NaT for an ambiguous time.
            * 'raise' will raise an AmbiguousTimeError for an ambiguous time.

            .. versionadded:: 0.24.0
        nonexistent : {'raise', 'shift_forward', 'shift_backward, 'NaT', \
timedelta}, default 'raise'
            A nonexistent time does not exist in a particular timezone
            where clocks moved forward due to DST.

            * 'shift_forward' will shift the nonexistent time forward to the
              closest existing time.
            * 'shift_backward' will shift the nonexistent time backward to the
              closest existing time.
            * 'NaT' will return NaT where there are nonexistent times.
            * timedelta objects will shift nonexistent times by the timedelta.
            * 'raise' will raise an NonExistentTimeError if there are
              nonexistent times.

            .. versionadded:: 0.24.0

        Raises
        ------
        ValueError if the freq cannot be converted.
        """
        return self._round(freq, RoundTo.MINUS_INFTY, ambiguous, nonexistent)

    def ceil(self, freq, ambiguous='raise', nonexistent='raise'):
        """
        return a new Timestamp ceiled to this resolution.

        Parameters
        ----------
        freq : str
            Frequency string indicating the ceiling resolution.
        ambiguous : bool or {'raise', 'NaT'}, default 'raise'
            The behavior is as follows:

            * bool contains flags to determine if time is dst or not (note
              that this flag is only applicable for ambiguous fall dst dates).
            * 'NaT' will return NaT for an ambiguous time.
            * 'raise' will raise an AmbiguousTimeError for an ambiguous time.

            .. versionadded:: 0.24.0
        nonexistent : {'raise', 'shift_forward', 'shift_backward, 'NaT', \
timedelta}, default 'raise'
            A nonexistent time does not exist in a particular timezone
            where clocks moved forward due to DST.

            * 'shift_forward' will shift the nonexistent time forward to the
              closest existing time.
            * 'shift_backward' will shift the nonexistent time backward to the
              closest existing time.
            * 'NaT' will return NaT where there are nonexistent times.
            * timedelta objects will shift nonexistent times by the timedelta.
            * 'raise' will raise an NonExistentTimeError if there are
              nonexistent times.

            .. versionadded:: 0.24.0

        Raises
        ------
        ValueError if the freq cannot be converted.
        """
        return self._round(freq, RoundTo.PLUS_INFTY, ambiguous, nonexistent)

    @property
    def tz(self):
        """
        Alias for tzinfo.
        """
        return self.tzinfo

    @tz.setter
    def tz(self, value):
        # GH 3746: Prevent localizing or converting the index by setting tz
        raise AttributeError(
            "Cannot directly set timezone. "
            "Use tz_localize() or tz_convert() as appropriate"
        )

    def __setstate__(self, state):
        self.value = state[0]
        self.freq = state[1]
        self.tzinfo = state[2]

    def __reduce__(self):
        object_state = self.value, self.freq, self.tzinfo
        return (Timestamp, object_state)

    def to_period(self, freq=None):
        """
        Return an period of which this timestamp is an observation.
        """
        from pandas import Period

        if self.tz is not None:
            # GH#21333
            warnings.warn(
                "Converting to Period representation will drop timezone information.",
                UserWarning,
            )

        if freq is None:
            freq = self.freq

        return Period(self, freq=freq)

    @property
    def dayofweek(self) -> int:
        """
        Return day of the week.
        """
        return self.weekday()

    def day_name(self, locale=None) -> str:
        """
        Return the day name of the Timestamp with specified locale.

        Parameters
        ----------
        locale : string, default None (English locale)
            Locale determining the language in which to return the day name.

        Returns
        -------
        day_name : string

        .. versionadded:: 0.23.0
        """
        return self._get_date_name_field('day_name', locale)

    def month_name(self, locale=None) -> str:
        """
        Return the month name of the Timestamp with specified locale.

        Parameters
        ----------
        locale : string, default None (English locale)
            Locale determining the language in which to return the month name.

        Returns
        -------
        month_name : string

        .. versionadded:: 0.23.0
        """
        return self._get_date_name_field('month_name', locale)

    @property
    def dayofyear(self) -> int:
        """
        Return the day of the year.
        """
        return ccalendar.get_day_of_year(self.year, self.month, self.day)

    @property
    def week(self) -> int:
        """
        Return the week number of the year.
        """
        return ccalendar.get_week_of_year(self.year, self.month, self.day)

    weekofyear = week

    @property
    def quarter(self) -> int:
        """
        Return the quarter of the year.
        """
        return ((self.month - 1) // 3) + 1

    @property
    def days_in_month(self) -> int:
        """
        Return the number of days in the month.
        """
        return ccalendar.get_days_in_month(self.year, self.month)

    daysinmonth = days_in_month

    @property
    def freqstr(self):
        """
        Return the total number of days in the month.
        """
        return getattr(self.freq, 'freqstr', self.freq)

    @property
    def is_month_start(self) -> bool:
        """
        Return True if date is first day of month.
        """
        if self.freq is None:
            # fast-path for non-business frequencies
            return self.day == 1
        return self._get_start_end_field('is_month_start')

    @property
    def is_month_end(self) -> bool:
        """
        Return True if date is last day of month.
        """
        if self.freq is None:
            # fast-path for non-business frequencies
            return self.day == self.days_in_month
        return self._get_start_end_field('is_month_end')

    @property
    def is_quarter_start(self) -> bool:
        """
        Return True if date is first day of the quarter.
        """
        if self.freq is None:
            # fast-path for non-business frequencies
            return self.day == 1 and self.month % 3 == 1
        return self._get_start_end_field('is_quarter_start')

    @property
    def is_quarter_end(self) -> bool:
        """
        Return True if date is last day of the quarter.
        """
        if self.freq is None:
            # fast-path for non-business frequencies
            return (self.month % 3) == 0 and self.day == self.days_in_month
        return self._get_start_end_field('is_quarter_end')

    @property
    def is_year_start(self) -> bool:
        """
        Return True if date is first day of the year.
        """
        if self.freq is None:
            # fast-path for non-business frequencies
            return self.day == self.month == 1
        return self._get_start_end_field('is_year_start')

    @property
    def is_year_end(self) -> bool:
        """
        Return True if date is last day of the year.
        """
        if self.freq is None:
            # fast-path for non-business frequencies
            return self.month == 12 and self.day == 31
        return self._get_start_end_field('is_year_end')

    @property
    def is_leap_year(self) -> bool:
        """
        Return True if year is a leap year.
        """
        return bool(ccalendar.is_leapyear(self.year))

    def tz_localize(self, tz, ambiguous='raise', nonexistent='raise'):
        """
        Convert naive Timestamp to local time zone, or remove
        timezone from tz-aware Timestamp.

        Parameters
        ----------
        tz : str, pytz.timezone, dateutil.tz.tzfile or None
            Time zone for time which Timestamp will be converted to.
            None will remove timezone holding local time.

        ambiguous : bool, 'NaT', default 'raise'
            When clocks moved backward due to DST, ambiguous times may arise.
            For example in Central European Time (UTC+01), when going from
            03:00 DST to 02:00 non-DST, 02:30:00 local time occurs both at
            00:30:00 UTC and at 01:30:00 UTC. In such a situation, the
            `ambiguous` parameter dictates how ambiguous times should be
            handled.

            The behavior is as follows:

            * bool contains flags to determine if time is dst or not (note
              that this flag is only applicable for ambiguous fall dst dates).
            * 'NaT' will return NaT for an ambiguous time.
            * 'raise' will raise an AmbiguousTimeError for an ambiguous time.

        nonexistent : 'shift_forward', 'shift_backward, 'NaT', timedelta, \
default 'raise'
            A nonexistent time does not exist in a particular timezone
            where clocks moved forward due to DST.

            The behavior is as follows:

            * 'shift_forward' will shift the nonexistent time forward to the
              closest existing time.
            * 'shift_backward' will shift the nonexistent time backward to the
              closest existing time.
            * 'NaT' will return NaT where there are nonexistent times.
            * timedelta objects will shift nonexistent times by the timedelta.
            * 'raise' will raise an NonExistentTimeError if there are
              nonexistent times.

            .. versionadded:: 0.24.0

        Returns
        -------
        localized : Timestamp

        Raises
        ------
        TypeError
            If the Timestamp is tz-aware and tz is not None.
        """
        if ambiguous == 'infer':
            raise ValueError('Cannot infer offset with only one time.')

        nonexistent_options = ('raise', 'NaT', 'shift_forward', 'shift_backward')
        if nonexistent not in nonexistent_options and not PyDelta_Check(nonexistent):
            raise ValueError(
                "The nonexistent argument must be one of 'raise', "
                "'NaT', 'shift_forward', 'shift_backward' or a timedelta object"
            )

        if self.tzinfo is None:
            # tz naive, localize
            tz = maybe_get_tz(tz)
            if not isinstance(ambiguous, str):
                ambiguous = [ambiguous]
            value = tz_localize_to_utc(np.array([self.value], dtype='i8'), tz,
                                       ambiguous=ambiguous,
                                       nonexistent=nonexistent)[0]
            return Timestamp(value, tz=tz, freq=self.freq)
        else:
            if tz is None:
                # reset tz
                value = tz_convert_single(self.value, UTC, self.tz)
                return Timestamp(value, tz=tz, freq=self.freq)
            else:
                raise TypeError(
                    "Cannot localize tz-aware Timestamp, use tz_convert for conversions"
                )

    def tz_convert(self, tz):
        """
        Convert tz-aware Timestamp to another time zone.

        Parameters
        ----------
        tz : str, pytz.timezone, dateutil.tz.tzfile or None
            Time zone for time which Timestamp will be converted to.
            None will remove timezone holding UTC time.

        Returns
        -------
        converted : Timestamp

        Raises
        ------
        TypeError
            If Timestamp is tz-naive.
        """
        if self.tzinfo is None:
            # tz naive, use tz_localize
            raise TypeError(
                "Cannot convert tz-naive Timestamp, use tz_localize to localize"
            )
        else:
            # Same UTC timestamp, different time zone
            return Timestamp(self.value, tz=tz, freq=self.freq)

    astimezone = tz_convert

    def replace(
        self,
        year=None,
        month=None,
        day=None,
        hour=None,
        minute=None,
        second=None,
        microsecond=None,
        nanosecond=None,
        tzinfo=object,
        fold=0,
    ):
        """
        implements datetime.replace, handles nanoseconds.

        Parameters
        ----------
        year : int, optional
        month : int, optional
        day : int, optional
        hour : int, optional
        minute : int, optional
        second : int, optional
        microsecond : int, optional
        nanosecond : int, optional
        tzinfo : tz-convertible, optional
        fold : int, optional, default is 0

        Returns
        -------
        Timestamp with fields replaced
        """

        cdef:
            npy_datetimestruct dts
            int64_t value, value_tz, offset
            object _tzinfo, result, k, v
            datetime ts_input

        # set to naive if needed
        _tzinfo = self.tzinfo
        value = self.value
        if _tzinfo is not None:
            value_tz = tz_convert_single(value, _tzinfo, UTC)
            value += value - value_tz

        # setup components
        dt64_to_dtstruct(value, &dts)
        dts.ps = self.nanosecond * 1000

        # replace
        def validate(k, v):
            """ validate integers """
            if not is_integer_object(v):
                raise ValueError(
                    f"value must be an integer, received {type(v)} for {k}"
                )
            return v

        if year is not None:
            dts.year = validate('year', year)
        if month is not None:
            dts.month = validate('month', month)
        if day is not None:
            dts.day = validate('day', day)
        if hour is not None:
            dts.hour = validate('hour', hour)
        if minute is not None:
            dts.min = validate('minute', minute)
        if second is not None:
            dts.sec = validate('second', second)
        if microsecond is not None:
            dts.us = validate('microsecond', microsecond)
        if nanosecond is not None:
            dts.ps = validate('nanosecond', nanosecond) * 1000
        if tzinfo is not object:
            _tzinfo = tzinfo

        # reconstruct & check bounds
        if _tzinfo is not None and treat_tz_as_pytz(_tzinfo):
            # replacing across a DST boundary may induce a new tzinfo object
            # see GH#18319
            ts_input = _tzinfo.localize(datetime(dts.year, dts.month, dts.day,
                                                 dts.hour, dts.min, dts.sec,
                                                 dts.us),
                                        is_dst=not bool(fold))
            _tzinfo = ts_input.tzinfo
        else:
            kwargs = {'year': dts.year, 'month': dts.month, 'day': dts.day,
                      'hour': dts.hour, 'minute': dts.min, 'second': dts.sec,
                      'microsecond': dts.us, 'tzinfo': _tzinfo,
                      'fold': fold}
            ts_input = datetime(**kwargs)

        ts = convert_datetime_to_tsobject(ts_input, _tzinfo)
        value = ts.value + (dts.ps // 1000)
        if value != NPY_NAT:
            check_dts_bounds(&dts)

        return create_timestamp_from_ts(value, dts, _tzinfo, self.freq, fold)

    def isoformat(self, sep='T'):
        base = super(_Timestamp, self).isoformat(sep=sep)
        if self.nanosecond == 0:
            return base

        if self.tzinfo is not None:
            base1, base2 = base[:-6], base[-6:]
        else:
            base1, base2 = base, ""

        if self.microsecond != 0:
            base1 += f"{self.nanosecond:03d}"
        else:
            base1 += f".{self.nanosecond:09d}"

        return base1 + base2

    def to_julian_date(self) -> np.float64:
        """
        Convert TimeStamp to a Julian Date.
        0 Julian date is noon January 1, 4713 BC.
        """
        year = self.year
        month = self.month
        day = self.day
        if month <= 2:
            year -= 1
            month += 12
        return (day +
                np.fix((153 * month - 457) / 5) +
                365 * year +
                np.floor(year / 4) -
                np.floor(year / 100) +
                np.floor(year / 400) +
                1721118.5 +
                (self.hour +
                 self.minute / 60.0 +
                 self.second / 3600.0 +
                 self.microsecond / 3600.0 / 1e+6 +
                 self.nanosecond / 3600.0 / 1e+9
                ) / 24.0)

    def normalize(self):
        """
        Normalize Timestamp to midnight, preserving tz information.
        """
        if self.tz is None or is_utc(self.tz):
            DAY_NS = ccalendar.DAY_NANOS
            normalized_value = self.value - (self.value % DAY_NS)
            return Timestamp(normalized_value).tz_localize(self.tz)
        normalized_value = normalize_i8_timestamps(
            np.array([self.value], dtype='i8'), tz=self.tz)[0]
        return Timestamp(normalized_value).tz_localize(self.tz)


# Add the min and max fields at the class level
cdef int64_t _NS_UPPER_BOUND = np.iinfo(np.int64).max
# the smallest value we could actually represent is
#   INT64_MIN + 1 == -9223372036854775807
# but to allow overflow free conversion with a microsecond resolution
# use the smallest value with a 0 nanosecond unit (0s in last 3 digits)
cdef int64_t _NS_LOWER_BOUND = -9_223_372_036_854_775_000

# Resolution is in nanoseconds
Timestamp.min = Timestamp(_NS_LOWER_BOUND)
Timestamp.max = Timestamp(_NS_UPPER_BOUND)
Timestamp.resolution = Timedelta(nanoseconds=1)  # GH#21336, GH#21365

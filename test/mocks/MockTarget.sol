// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.35;

contract MockTarget {
    error MockTargetRevert(uint256 code);

    bool public shouldRevert;
    uint256 public callCount;

    address public reenterTarget;
    bytes public reenterData;
    uint256 public reenterValue;

    bytes[] internal _datas;
    uint256[] internal _values;

    function setRevert(bool revert_) external {
        shouldRevert = revert_;
    }

    function setReenter(address target, bytes memory data, uint256 value) external {
        reenterTarget = target;
        reenterData = data;
        reenterValue = value;
    }

    function dataAt(uint256 index) external view returns (bytes memory) {
        return _datas[index];
    }

    function valueAt(uint256 index) external view returns (uint256) {
        return _values[index];
    }

    function lastData() external view returns (bytes memory) {
        return _datas[_datas.length - 1];
    }

    function lastValue() external view returns (uint256) {
        return _values[_values.length - 1];
    }

    receive() external payable {
        _record();
    }

    fallback() external payable {
        _record();
    }

    function _record() internal {
        if (shouldRevert) revert MockTargetRevert(callCount);

        callCount += 1;
        _datas.push(msg.data);
        _values.push(msg.value);

        address target = reenterTarget;
        if (target != address(0x00)) {
            reenterTarget = address(0x00);
            (bool success,) = target.call{value: reenterValue}(reenterData);
            require(success);
        }
    }
}

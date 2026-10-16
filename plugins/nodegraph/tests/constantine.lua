function mahOtherFunc(someShietToo)
    -- stuff...
end

function mahFunc(someShiet)
    mahOtherFunc(someShiet)
    -- stuff...
end

for i = 0, 10000 do
    mahFunc(i * i)
    dd.log(i * i)
end

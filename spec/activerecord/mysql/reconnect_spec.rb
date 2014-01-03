describe Hash do
  it 'select all' do
    expect {
      expect(Employee.all.length).to eq(300024)
      mysql_restart
      expect(Employee.all.length).to eq(300024)
    }.to_not raise_error
  end

  it 'count' do
    expect {
      expect(Employee.count).to eq(300024)
      mysql_restart
      expect(Employee.count).to eq(300024)
    }.to_not raise_error
  end

  it 'on select' do
    expect {
      thread_running = false

      th = Thread.start {
        thread_running = true
        expect(Employee.where(:id => 1).pluck('sleep(15)')).to eq([1])
        thread_running = false
      }

      th.abort_on_exception = true
      sleep 3
      expect(thread_running).to be_true
      mysql_restart
      expect(Employee.count).to eq(300024)
      th.join
    }.to_not raise_error
  end

  it 'on insert' do
    expect {
      thread_running = false

      th = Thread.start {
        thread_running = true
        emp = Employee.create(
                :emp_no     => '0',
                :birth_date => Time.now,
                :first_name => "' + sleep(15) + '",
                :last_name  => 'Tiger',
                :hire_date  => Time.now
              )
        thread_running = false
        expect(emp.id).to eq(327676)
      }

      th.abort_on_exception = true
      sleep 3
      expect(thread_running).to be_true
      mysql_restart
      expect(Employee.count).to eq(300024)
      th.join
    }.to_not raise_error
  end
end
